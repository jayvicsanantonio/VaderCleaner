// ExtensionsManagerViewModel.swift
// State machine behind the Extensions Manager view — runs the discoverers concurrently, groups results by ExtensionType, and routes removal between FileManager (user paths) and the privileged helper (/Library paths).

import Foundation
import Observation
import os.log

/// Drives the Extensions Manager feature view (discover → group → remove).
///
/// Collaborators are injected as closures so unit tests can drive every
/// transition without touching real extension state. Production wiring lives
/// in `ExtensionsManagerViewModel.live()` below.
@MainActor
@Observable
public final class ExtensionsManagerViewModel {

    /// Which step produced a `.failed` phase, so the view can pick the
    /// right heading and recovery affordance.
    public enum FailureStage: Equatable {
        case loading
        case removing
    }

    /// Discrete phases the view binds to.
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case removing
        case failed(stage: FailureStage, message: String)
    }

    public typealias Discover = () async throws -> [ExtensionItem]
    public typealias Remove   = (ExtensionItem) async throws -> Void

    public private(set) var phase: Phase = .idle
    public private(set) var items: [ExtensionItem] = []

    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let removal: Remove
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "ExtensionsManagerViewModel")

    /// Monotonically increasing token so a stale discovery pass that
    /// resolves after a newer `refresh()` can't clobber fresh state — same
    /// pattern as the other feature view-models.
    @ObservationIgnored private var loadGeneration = 0

    public init(
        discover: @escaping Discover,
        remove: @escaping Remove
    ) {
        self.discover = discover
        self.removal = remove
    }

    // MARK: - Public surface

    /// Discovered items bucketed by `ExtensionType`, emitted in
    /// `ExtensionType.allCases` declaration order with empty buckets
    /// skipped. The view renders one section per tuple.
    public var groupedByType: [(ExtensionType, [ExtensionItem])] {
        var bucket: [ExtensionType: [ExtensionItem]] = [:]
        for item in items {
            bucket[item.type, default: []].append(item)
        }
        return ExtensionType.allCases.compactMap { type in
            guard let entries = bucket[type], !entries.isEmpty else { return nil }
            let sorted = entries.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return (type, sorted)
        }
    }

    /// The removal failure to show in the manager's result banner.
    public var notice: ManagerNotice? {
        guard case .failed(.removing, let message) = phase else { return nil }
        return ManagerNotice(message: message, isError: true)
    }

    /// The discovery failure's message. An empty list here says nothing about
    /// what's installed, so the pane shows this instead of its empty state.
    public var loadFailureMessage: String? {
        guard case .failed(.loading, let message) = phase else { return nil }
        return message
    }

    /// Whether removing `ids` deletes anything outright. The privileged helper
    /// can't reach the user's Trash, so system-wide plug-ins don't get one, and
    /// the confirmation has to say so.
    public func includesPermanentRemoval(_ ids: Set<ExtensionItem.ID>) -> Bool {
        items.contains { ids.contains($0.id) && SystemJunkDeleter.requiresHelper(path: $0.path.path) }
    }

    // MARK: - Actions

    /// Runs discovery and lands `.ready` (or `.failed(.loading)`).
    public func refresh() async {
        let generation = beginLoad()
        phase = .loading
        do {
            let result = try await discover()
            guard loadGeneration == generation else { return }
            items = result
            phase = .ready
        } catch {
            // Privacy: discovery errors may include user-specific paths.
            log.error("Extension discovery failed: \(String(describing: error), privacy: .private)")
            guard loadGeneration == generation else { return }
            items = []
            phase = .failed(stage: .loading, message: error.localizedDescription)
        }
    }

    /// Removes a single item. On success the row is dropped and the VM
    /// returns to `.ready`; on failure the list is left intact so the user
    /// can retry.
    /// Removes several extensions as one operation.
    ///
    /// Driving this from the view — `for item in targets { await remove(item) }`
    /// — ran a *single-item* phase machine N times, so item N's `.failed` was
    /// overwritten by item N+1's `.removing` and the failure was never rendered
    /// anywhere. The batch's outcome is one value here instead of N overwrites,
    /// and `.removing` is held for the whole pass so the footer can gate on it.
    ///
    /// Best-effort, matching `AppUninstallerViewModel.uninstallSelected()`: the
    /// extensions that were removed are dropped from the list, and a failure is
    /// surfaced only if something actually failed.
    public func removeSelected(_ ids: Set<ExtensionItem.ID>) async {
        guard phase != .removing else { return }
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }

        phase = .removing
        var removedIDs: Set<ExtensionItem.ID> = []
        var lastError: Error?
        for item in targets {
            do {
                try await removal(item)
                removedIDs.insert(item.id)
            } catch {
                // Privacy: removal errors may include user-specific paths.
                log.error("Extension removal failed: \(String(describing: error), privacy: .private)")
                lastError = error
            }
        }
        items.removeAll { removedIDs.contains($0.id) }
        if let lastError {
            phase = .failed(
                stage: .removing,
                message: HelperConnectionError.userFacingMessage(for: lastError)
            )
        } else {
            phase = .ready
        }
    }

    func remove(_ item: ExtensionItem) async {
        phase = .removing
        do {
            try await removal(item)
            items.removeAll { $0.id == item.id }
            phase = .ready
        } catch {
            // Privacy: removal errors may include user-specific paths.
            log.error("Extension removal failed: \(String(describing: error), privacy: .private)")
            phase = .failed(
                stage: .removing,
                message: HelperConnectionError.userFacingMessage(for: error)
            )
        }
    }

    /// Returns the VM to `.ready` after a `.failed` phase so the user can
    /// retry without re-running discovery.
    public func dismissResult() {
        phase = .ready
    }

    // MARK: - Generations

    private func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }
}

// MARK: - Production wiring

extension ExtensionsManagerViewModel {

    /// Builds a view-model wired to the real discoverers (run concurrently)
    /// and the path-routed removal pipeline.
    @MainActor
    public static func live() -> ExtensionsManagerViewModel {
        ExtensionsManagerViewModel(
            discover: {
                async let safari   = SafariExtensionDiscovery().extensions()
                async let browser  = BrowserExtensionDiscovery().extensions()
                async let mail     = MailPluginDiscovery().extensions()
                async let internet = InternetPluginDiscovery().extensions()
                // Not sorted here: `groupedByType` sorts each bucket by
                // name before the data reaches the UI.
                return await safari + browser + mail + internet
            },
            remove: { item in
                try await Self.removeItem(
                    item,
                    recycle: { await UserFileRecycler.recycle($0, context: "Extensions") },
                    deleteViaHelper: { path in
                        try await Self.helperCall { helper, done in
                            helper.deleteFiles([path], reply: done)
                        }
                    }
                )
            }
        )
    }

    /// Routes removal by privilege need. User-writable paths (`~/Library/…`)
    /// go to the Trash, so a change of heart is recoverable. Paths under
    /// `/Library` or `/System` (system Mail bundles, system internet plug-ins)
    /// go through the privileged helper via the batched `deleteFiles(_:)`,
    /// which deletes them outright.
    nonisolated static func removeItem(
        _ item: ExtensionItem,
        recycle: @Sendable ([URL]) async -> Set<URL>,
        deleteViaHelper: @Sendable (String) async throws -> Void
    ) async throws {
        let path = item.path.path
        guard SystemJunkDeleter.requiresHelper(path: path) else {
            let moved = await recycle([item.path])
            guard moved.contains(where: { $0.path == path }) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "\(item.name) couldn't be moved to the Trash.",
                        bundle: .module,
                        comment: "Extension removal failure; the extension's name."
                    )
                ])
            }
            return
        }
        try await deleteViaHelper(path)
    }

    /// Bridges a reply-block helper call to async/throwing. See `HelperCall`
    /// for the once-only resumption and watchdog this relies on.
    private nonisolated static func helperCall(
        _ body: HelperCall.Invoke
    ) async throws {
        let error = await HelperCall.perform(
            helperProvider: SystemJunkDeleter.defaultHelperProvider,
            body
        )
        if let error { throw error }
    }
}
