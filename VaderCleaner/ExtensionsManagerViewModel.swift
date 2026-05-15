// ExtensionsManagerViewModel.swift
// State machine behind the Extensions Manager view — runs the five discoverers concurrently, groups results by ExtensionType, and routes removal between FileManager (user paths) and the privileged helper (/Library paths).

import Foundation
import os.log

/// Drives the Extensions Manager feature view (discover → group → remove).
///
/// Collaborators are injected as closures so unit tests can drive every
/// transition without touching real extension state. Production wiring lives
/// in `ExtensionsManagerViewModel.live()` below.
@MainActor
final class ExtensionsManagerViewModel: ObservableObject {

    /// Which step produced a `.failed` phase, so the view can pick the
    /// right heading and recovery affordance.
    enum FailureStage: Equatable {
        case loading
        case removing
    }

    /// Discrete phases the view binds to.
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case removing
        case failed(stage: FailureStage, message: String)
    }

    typealias Discover = () async throws -> [ExtensionItem]
    typealias Remove   = (ExtensionItem) async throws -> Void

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [ExtensionItem] = []

    private let discover: Discover
    private let removal: Remove
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "ExtensionsManagerViewModel")

    /// Monotonically increasing token so a stale discovery pass that
    /// resolves after a newer `refresh()` can't clobber fresh state — same
    /// pattern as the other feature view-models.
    private var loadGeneration = 0

    init(
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
    var groupedByType: [(ExtensionType, [ExtensionItem])] {
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

    // MARK: - Actions

    /// Runs discovery and lands `.ready` (or `.failed(.loading)`).
    func refresh() async {
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
    func remove(_ item: ExtensionItem) async {
        phase = .removing
        do {
            try await removal(item)
            items.removeAll { $0.id == item.id }
            phase = .ready
        } catch {
            // Privacy: removal errors may include user-specific paths.
            log.error("Extension removal failed: \(String(describing: error), privacy: .private)")
            phase = .failed(stage: .removing, message: error.localizedDescription)
        }
    }

    /// Returns the VM to `.ready` after a `.failed` phase so the user can
    /// retry without re-running discovery.
    func dismissResult() {
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

    /// Builds a view-model wired to the five real discoverers (run
    /// concurrently) and the path-routed removal pipeline.
    @MainActor
    static func live() -> ExtensionsManagerViewModel {
        ExtensionsManagerViewModel(
            discover: {
                async let safari   = SafariExtensionDiscovery().extensions()
                async let browser  = BrowserExtensionDiscovery().extensions()
                async let mail     = MailPluginDiscovery().extensions()
                async let internet = InternetPluginDiscovery().extensions()
                async let agents   = LaunchAgentDiscovery().extensions()
                let merged = await safari + browser + mail + internet + agents
                return merged.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            },
            remove: { item in
                try await Self.removeItem(item)
            }
        )
    }

    /// Routes removal by privilege need. User-writable paths (`~/Library/…`,
    /// including `~/Library/LaunchAgents`) are removed in-process. Paths
    /// under `/Library` or `/System` (system Mail bundles, system internet
    /// plug-ins) go through the privileged helper — launch-agent plists via
    /// the dedicated `removeLaunchAgent(path:)`, everything else via the
    /// batched `deleteFiles(_:)`.
    private static func removeItem(_ item: ExtensionItem) async throws {
        let path = item.path.path
        guard SystemJunkDeleter.requiresHelper(path: path) else {
            try FileManager.default.removeItem(at: item.path)
            return
        }
        if item.type == .loginItemFromApp {
            try await helperCall { helper, done in
                helper.removeLaunchAgent(path: path, reply: done)
            }
        } else {
            try await helperCall { helper, done in
                helper.deleteFiles([path], reply: done)
            }
        }
    }

    /// Bridges a reply-block helper call to async/throwing. Installs both
    /// the per-call XPC error handler and the reply block; whichever fires
    /// first resumes the continuation (the other becomes a no-op via the
    /// once-only guard) so a dropped connection can't freeze removal.
    private static func helperCall(
        _ body: @escaping (VaderCleanerHelperProtocol, @escaping (Error?) -> Void) -> Void
    ) async throws {
        let error: Error? = await withCheckedContinuation { continuation in
            let resumer = OnceResumer(continuation)
            let helper = HelperConnectionManager.shared.helper { connectionError in
                resumer.resume(with: connectionError)
            }
            guard let helper else {
                resumer.resume(with: NSError(
                    domain: "com.personal.VaderCleaner.ExtensionsManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Helper unavailable"]
                ))
                return
            }
            body(helper) { replyError in
                resumer.resume(with: replyError)
            }
        }
        if let error { throw error }
    }
}

/// Once-only continuation resume. The XPC reply block and the
/// connection-level error handler may both fire; `CheckedContinuation`
/// traps on a second resume, so the first wins and later attempts are
/// dropped. A class because multiple closures reference it; `NSLock`
/// covers the "two callbacks on different threads" race.
private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?

    init(_ continuation: CheckedContinuation<Error?, Never>) {
        self.continuation = continuation
    }

    func resume(with error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: error)
    }
}
