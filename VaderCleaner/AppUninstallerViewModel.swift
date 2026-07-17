// AppUninstallerViewModel.swift
// State machine and selection logic behind the App Uninstaller feature view — drives idle/loading/ready/uninstalling/complete transitions and routes the uninstall through an injected recycler.

import AppKit
import Foundation
import Observation
import os.log

/// Drives the App Uninstaller feature view (load apps → select → uninstall → done).
///
/// Like `PrivacyViewModel` and `SystemJunkViewModel`, all collaborators are
/// injected as closures so unit tests can drive every transition without
/// touching real disk state. Production wiring lives in
/// `AppUninstallerViewModel.live()` below.
@MainActor
@Observable
final class AppUninstallerViewModel {

    /// Which step of the flow generated a `.failed` phase, so the view can
    /// pick the right heading.
    enum FailureStage: Equatable {
        case loading
        case uninstalling
    }

    /// Discrete phases the view binds to.
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case uninstalling
        /// `permanentRemoval` is true when the app bundle was permanently
        /// removed (root-owned / App Store app the user couldn't Trash)
        /// rather than moved to the Trash, so the completion screen can stay
        /// truthful about whether the app can be restored.
        case complete(bytesFreed: Int64, permanentRemoval: Bool)
        /// `helperConnectionIssue` is true when the failure was the privileged
        /// helper being unreachable, so the failure screen can offer a
        /// "Reinstall Helper" recovery instead of a plain retry.
        case failed(stage: FailureStage, message: String, helperConnectionIssue: Bool)
    }

    /// Result of a recycle: how many bytes were actually freed, and whether
    /// the bundle had to be permanently removed via the privileged helper
    /// (because the user couldn't move a root-owned bundle to the Trash).
    struct RecycleOutcome: Equatable, Sendable {
        let bytesFreed: Int64
        let bundlePermanentlyRemoved: Bool
    }

    typealias Discover     = @Sendable (_ includingSystemApps: Bool) async throws -> [AppInfo]
    typealias FindFiles    = @Sendable (_ bundleID: String) async -> [AssociatedFile]
    typealias MeasureSize  = @Sendable (_ bundleURL: URL) async -> Int64
    /// One incremental slice of measured list metrics: a subset of the pending
    /// apps' bundle sizes and Spotlight last-opened dates.
    typealias ListMetricsChunk = (sizes: [AppInfo.ID: Int64], dates: [AppInfo.ID: Date])
    /// Streaming metrics walk for the Applications Manager's uninstaller list:
    /// yields each app's bundle size and Spotlight last-opened date in chunks as
    /// the background pass measures them, so the list fills in progressively
    /// rather than snapping every row to its value only when the whole walk
    /// finishes. The size walk over many bundles is the expensive measurement
    /// discovery deliberately skips, which is why it streams off the main actor.
    typealias MeasureListMetrics = @Sendable (_ apps: [AppInfo]) -> AsyncStream<ListMetricsChunk>
    /// Recycler contract: takes the `.app` bundle URL and the associated
    /// file URLs separately so the production implementation can verify
    /// the bundle itself was moved (and not just the user-writable
    /// residue). Reports the bytes actually freed and whether the bundle
    /// was permanently removed rather than Trashed.
    typealias Recycle      = @Sendable (_ bundleURL: URL, _ associatedURLs: [URL]) async throws -> RecycleOutcome
    /// Forces a clean re-registration of the privileged helper and points the
    /// user at the approval UI. Injected so tests don't touch `SMAppService`.
    typealias ReinstallHelper = @Sendable () async -> Void

    private(set) var phase: Phase = .idle
    private(set) var apps: [AppInfo] = []
    private(set) var selectedAppID: AppInfo.ID?
    private(set) var associatedFiles: [AssociatedFile] = []
    private(set) var isLoadingAssociatedFiles: Bool = false
    /// Bundle size of the currently selected app, computed lazily on
    /// selection. `nil` until the per-app size measurement returns.
    private(set) var selectedAppBundleSize: Int64?
    var includesSystemApps: Bool = false
    var searchQuery: String = ""

    /// Apps checked for the Applications Manager's batch uninstall, keyed by
    /// `AppInfo.ID`. Separate from `selectedAppID` (which drives the single-app
    /// associated-files inspector behind each row's chevron) so the multi-select
    /// list and the detail inspector don't fight over one selection.
    private(set) var uninstallSelection: Set<AppInfo.ID> = []

    /// Session-scoped per-app size and last-opened caches the Applications
    /// Manager's uninstaller list sorts and renders by. Populated once by
    /// `loadListMetrics()` and retained for the session so reopening the manager
    /// reuses them instead of re-walking the disk. Observable so the list
    /// re-renders when the measured values land.
    private(set) var listSizes: [AppInfo.ID: Int64] = [:]
    private(set) var listLastOpened: [AppInfo.ID: Date] = [:]
    /// Apps that have completed a metrics pass, tracked separately from the
    /// value caches because a `nil` last-opened date is a valid result (Spotlight
    /// has no record) — inferring "measured" from the dictionaries would re-walk
    /// those apps forever.
    @ObservationIgnored private var measuredListMetricApps: Set<AppInfo.ID> = []
    /// Bumped once a metrics stream finishes so the manager's memoized list
    /// re-sorts into its final order. The per-chunk dictionary merges above
    /// already re-render each row's size/date as the values stream in; this
    /// gives the sort a single settle at the end rather than reordering the
    /// whole list on every chunk.
    private(set) var listMetricsRevision: Int = 0

    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let findFiles: FindFiles
    @ObservationIgnored private let measureSize: MeasureSize
    @ObservationIgnored private let measureListMetrics: MeasureListMetrics
    @ObservationIgnored private let recycle: Recycle
    @ObservationIgnored private let reinstallHelperService: ReinstallHelper
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "AppUninstallerViewModel")

    /// Cached associated-files results keyed by bundle URL path. Selecting
    /// the same app twice in a session doesn't re-walk the filesystem.
    @ObservationIgnored private var associatedFilesCache: [AppInfo.ID: [AssociatedFile]] = [:]

    /// Cached bundle sizes keyed by bundle URL path. The size walk is
    /// expensive on apps with many bundled frameworks, so we avoid
    /// repeating it after the first selection.
    @ObservationIgnored private var bundleSizeCache: [AppInfo.ID: Int64] = [:]

    /// Monotonically increasing token for in-flight operations — see the
    /// same pattern in `PrivacyViewModel` for the rationale.
    @ObservationIgnored private var loadGeneration: Int = 0
    @ObservationIgnored private var selectGeneration: Int = 0

    init(
        discover: @escaping Discover,
        findFiles: @escaping FindFiles,
        measureSize: @escaping MeasureSize = { _ in 0 },
        measureListMetrics: @escaping MeasureListMetrics = { _ in AsyncStream { $0.finish() } },
        recycle: @escaping Recycle,
        reinstallHelper: @escaping ReinstallHelper = {}
    ) {
        self.discover = discover
        self.findFiles = findFiles
        self.measureSize = measureSize
        self.measureListMetrics = measureListMetrics
        self.recycle = recycle
        self.reinstallHelperService = reinstallHelper
    }

    // MARK: - Public surface

    /// Convenience for the view layer — the currently selected `AppInfo`.
    var selectedApp: AppInfo? {
        guard let id = selectedAppID else { return nil }
        return apps.first(where: { $0.id == id })
    }

    /// Apps filtered by the current search query. Case-insensitive,
    /// substring match on name OR bundle ID. An empty query returns
    /// the full list.
    var filteredApps: [AppInfo] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(trimmed)
                || app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Sum of bundle size + all associated file sizes for the selected app.
    /// Returns 0 when nothing is selected — the footer renders "0 bytes" in
    /// that case, which is correct (nothing will be Trashed). The bundle
    /// size component is `nil` until the per-app size measurement
    /// returns; the footer reflects the partial total in the meantime.
    var totalReclaimableSize: Int64 {
        guard selectedApp != nil else { return 0 }
        let associated = associatedFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return (selectedAppBundleSize ?? 0) + associated
    }

    /// Associated files for the selected app grouped by category, in the
    /// stable declaration order of `AssociatedFileCategory.allCases`. The
    /// view renders one section per category.
    var associatedFilesByCategory: [(AssociatedFileCategory, [AssociatedFile])] {
        var bucketed: [AssociatedFileCategory: [AssociatedFile]] = [:]
        for file in associatedFiles {
            bucketed[file.category, default: []].append(file)
        }
        return AssociatedFileCategory.allCases.compactMap { category in
            guard let entries = bucketed[category], !entries.isEmpty else { return nil }
            return (category, entries)
        }
    }

    // MARK: - Actions

    /// Initial load — populates `apps` and lands in `.ready` (or `.failed`).
    func loadApps() async {
        let generation = beginLoad()
        phase = .loading
        let includes = includesSystemApps
        do {
            let result = try await discover(includes)
            guard self.loadGeneration == generation else { return }
            self.apps = result
            // Restore selection if the previously-selected app still exists,
            // otherwise drop it so the right-hand panel collapses to its
            // empty state.
            if let id = self.selectedAppID,
               result.contains(where: { $0.id == id }) {
                // keep current selection
            } else {
                self.selectedAppID = nil
                self.associatedFiles = []
            }
            self.phase = .ready
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("App discovery failed: \(String(describing: error), privacy: .private)")
            guard self.loadGeneration == generation else { return }
            self.apps = []
            self.selectedAppID = nil
            self.associatedFiles = []
            self.phase = .failed(stage: .loading,
                                 message: error.localizedDescription,
                                 helperConnectionIssue: false)
        }
    }

    /// Reloads the app list with the current `includesSystemApps` setting.
    /// Called by the view when the user flips the toggle so the visible
    /// list reflects the new filter immediately.
    func reloadApps() async {
        await loadApps()
    }

    /// Measures size and last-opened date for every app not already in the
    /// `listSizes` / `listLastOpened` caches, merging each streamed chunk as it
    /// arrives so rows fill in progressively instead of all at once when the
    /// whole walk finishes. Idempotent: apps measured earlier in the session are
    /// skipped, so the expensive disk walk runs once per app and reopening the
    /// manager reuses the cache. A no-op when nothing is pending — the revision
    /// only bumps when new metrics actually land.
    func loadListMetrics() async {
        let pending = apps.filter { !measuredListMetricApps.contains($0.id) }
        guard !pending.isEmpty else { return }
        // Merge each chunk rather than replace so apps already measured keep
        // their values, and each row updates the moment its metrics stream in.
        for await chunk in measureListMetrics(pending) {
            listSizes.merge(chunk.sizes) { _, new in new }
            listLastOpened.merge(chunk.dates) { _, new in new }
        }
        for app in pending { measuredListMetricApps.insert(app.id) }
        listMetricsRevision &+= 1
    }

    /// Select an app by ID. Drives an async associated-files lookup AND
    /// a deferred bundle-size measurement in parallel, publishing
    /// `associatedFiles` and `selectedAppBundleSize` independently as
    /// each one finishes. A second `select(...)` before the first
    /// finishes cancels the older lookups so the right-hand panel can't
    /// flash stale rows from a previous selection.
    func select(_ appID: AppInfo.ID?) {
        selectedAppID = appID
        guard let appID, let app = apps.first(where: { $0.id == appID }) else {
            associatedFiles = []
            selectedAppBundleSize = nil
            isLoadingAssociatedFiles = false
            return
        }

        // Hydrate cached results synchronously so the UI doesn't flash
        // back to "loading" for an app the user has already inspected.
        selectedAppBundleSize = bundleSizeCache[appID]

        if let cachedFiles = associatedFilesCache[appID] {
            associatedFiles = cachedFiles
            isLoadingAssociatedFiles = false
            // Bundle-size measurement may still be outstanding even when
            // associated files were cached (e.g. an error path skipped it
            // last time); fall through to schedule it if needed.
        } else {
            associatedFiles = []
            isLoadingAssociatedFiles = true
        }

        let generation = beginSelect()
        let bundleID = app.bundleID
        let bundleURL = app.bundleURL
        let findFiles = findFiles
        let measureSize = measureSize
        let needsFiles = associatedFilesCache[appID] == nil
        let needsSize = bundleSizeCache[appID] == nil

        if needsFiles {
            Task { [weak self] in
                let found = await findFiles(bundleID)
                await MainActor.run { [weak self] in
                    guard let self, self.selectGeneration == generation else { return }
                    self.associatedFilesCache[appID] = found
                    if self.selectedAppID == appID {
                        self.associatedFiles = found
                        self.isLoadingAssociatedFiles = false
                    }
                }
            }
        }

        if needsSize {
            Task { [weak self] in
                let size = await measureSize(bundleURL)
                await MainActor.run { [weak self] in
                    guard let self, self.selectGeneration == generation else { return }
                    self.bundleSizeCache[appID] = size
                    if self.selectedAppID == appID {
                        self.selectedAppBundleSize = size
                    }
                }
            }
        }
    }

    /// Bundle size for an app, if it has been measured. Used by the list
    /// row to show "— MB" only after the size lands rather than during
    /// the initial discovery pass.
    func bundleSize(for appID: AppInfo.ID) -> Int64? {
        bundleSizeCache[appID]
    }

    /// Whether the destructive uninstall button should be enabled for
    /// the currently selected app. False while the associated-files
    /// scan is in flight — confirming early would only Trash the bundle
    /// and leave residual user data behind.
    var canUninstallSelectedApp: Bool {
        selectedApp != nil && !isLoadingAssociatedFiles
    }

    /// Uninstall the currently-selected app. Routes the bundle URL plus
    /// every associated file URL through the injected recycler. A no-op
    /// when nothing is selected or when the associated-files scan is
    /// still in flight — confirming early would Trash only the bundle
    /// and leave residual user data behind.
    func uninstall() async {
        guard let app = selectedApp, !isLoadingAssociatedFiles else { return }
        let associatedURLs = associatedFiles.map { $0.url }
        phase = .uninstalling
        do {
            let outcome = try await recycle(app.bundleURL, associatedURLs)
            // Drop the app from the cached list and reset selection so the
            // user sees the result without a stale row pointing at a now-
            // removed bundle. `outcome.bytesFreed` is the recycler's
            // authoritative sum of what it actually removed — we do NOT fall
            // back to a planned/optimistic total, since that would claim
            // "X MB freed" when the recycler reports 0.
            apps.removeAll(where: { $0.id == app.id })
            selectedAppID = nil
            associatedFiles = []
            selectedAppBundleSize = nil
            associatedFilesCache.removeValue(forKey: app.id)
            bundleSizeCache.removeValue(forKey: app.id)
            phase = .complete(bytesFreed: outcome.bytesFreed,
                              permanentRemoval: outcome.bundlePermanentlyRemoved)
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("App uninstall failed: \(String(describing: error), privacy: .private)")
            // Route through the shared mapper so an unreachable privileged
            // helper surfaces the friendly "Helper is not responding" copy
            // instead of the cryptic "Couldn't communicate with a helper
            // application." NSXPC string. Non-connection errors (a real
            // permission denial) still pass through their own description.
            // Flag connection failures so the failure screen can offer to
            // reinstall the helper rather than only retry.
            phase = .failed(stage: .uninstalling,
                            message: HelperConnectionError.userFacingMessage(for: error),
                            helperConnectionIssue: HelperConnectionError.isConnectionFailure(error))
        }
    }

    /// Re-registers the privileged helper (and opens the approval UI) after a
    /// helper-connection failure, then reloads the app list so the user can
    /// retry the uninstall. Invoked by the "Reinstall Helper" action on the
    /// failure screen.
    func reinstallHelper() async {
        await reinstallHelperService()
        await loadApps()
    }

    /// Returns the VM to `.ready` after a complete / failed phase so the
    /// user can pick another app to uninstall without restarting the
    /// discovery scan.
    func dismissResult() {
        phase = .ready
    }

    // MARK: - Multi-select (Applications Manager)

    /// Whether `id` is checked for the batch uninstall.
    func isInUninstallSelection(_ id: AppInfo.ID) -> Bool {
        uninstallSelection.contains(id)
    }

    /// Toggle one app's checkbox in the batch-uninstall selection.
    func toggleUninstallSelection(_ id: AppInfo.ID) {
        if uninstallSelection.contains(id) {
            uninstallSelection.remove(id)
        } else {
            uninstallSelection.insert(id)
        }
    }

    /// Check exactly the supplied apps (e.g. the rows currently in view after a
    /// facet filter). Single write so SwiftUI observes one publish.
    func selectAllForUninstall(_ ids: [AppInfo.ID]) {
        uninstallSelection = Set(ids)
    }

    /// Uncheck everything — single-write counterpart to `selectAllForUninstall`.
    func clearUninstallSelection() {
        uninstallSelection = []
    }

    /// Whether the footer's Uninstall action should be enabled: something is
    /// checked and no batch is already running.
    var canUninstallSelection: Bool {
        guard !uninstallSelection.isEmpty else { return false }
        if case .uninstalling = phase { return false }
        return true
    }

    /// Batch-uninstall every checked app: for each, find its associated files
    /// and recycle the bundle plus those files, reusing the same primitives as
    /// the single-app `uninstall()`. Best-effort — a per-app failure leaves that
    /// app in the list (and selected, so the user can retry) while the rest are
    /// removed. Lands in `.complete` when at least one app was removed, or
    /// `.failed` when every selected app failed. A no-op when nothing is
    /// selected or a batch is already running.
    func uninstallSelected() async {
        let targets = apps.filter { uninstallSelection.contains($0.id) }
        guard !targets.isEmpty else { return }
        if case .uninstalling = phase { return }

        phase = .uninstalling
        var totalBytesFreed: Int64 = 0
        var anyPermanentRemoval = false
        var removedIDs: Set<AppInfo.ID> = []
        var lastError: Error?

        for app in targets {
            let associatedURLs = await findFiles(app.bundleID).map { $0.url }
            do {
                let outcome = try await recycle(app.bundleURL, associatedURLs)
                totalBytesFreed += outcome.bytesFreed
                anyPermanentRemoval = anyPermanentRemoval || outcome.bundlePermanentlyRemoved
                removedIDs.insert(app.id)
            } catch {
                // Privacy: errors may include user-specific paths.
                log.error("Batch uninstall of \(app.bundleID, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                lastError = error
            }
        }

        apps.removeAll { removedIDs.contains($0.id) }
        uninstallSelection.subtract(removedIDs)
        for id in removedIDs {
            associatedFilesCache.removeValue(forKey: id)
            bundleSizeCache.removeValue(forKey: id)
        }
        // If the inspector was showing a now-removed app, collapse it.
        if let selected = selectedAppID, removedIDs.contains(selected) {
            selectedAppID = nil
            associatedFiles = []
            selectedAppBundleSize = nil
        }

        if removedIDs.isEmpty, let lastError {
            phase = .failed(
                stage: .uninstalling,
                message: HelperConnectionError.userFacingMessage(for: lastError),
                helperConnectionIssue: HelperConnectionError.isConnectionFailure(lastError)
            )
        } else {
            phase = .complete(bytesFreed: totalBytesFreed, permanentRemoval: anyPermanentRemoval)
        }
    }

    // MARK: - Generations

    private func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    private func beginSelect() -> Int {
        selectGeneration += 1
        return selectGeneration
    }
}

// MARK: - Production wiring

extension AppUninstallerViewModel {

    /// Build a view-model wired to the real `DefaultAppDiscovery`,
    /// `DefaultAssociatedFileFinder`, and `NSWorkspace.recycle(...)`.
    /// The exclusions snapshot is captured per lookup (a fresh
    /// `DefaultAssociatedFileFinder` is cheap — it only stores config)
    /// so a freshly-added Preferences exclusion takes effect on the next
    /// app selection.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> AppUninstallerViewModel {
        let discovery = DefaultAppDiscovery()
        return AppUninstallerViewModel(
            discover: { includingSystemApps in
                try await discovery.installedApps(includingSystemApps: includingSystemApps)
            },
            findFiles: { [weak exclusions] bundleID in
                let excluded = await MainActor.run {
                    (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                }
                let finder = DefaultAssociatedFileFinder(excluding: excluded)
                return await finder.find(forBundleID: bundleID)
            },
            measureSize: { url in
                await discovery.bundleSize(at: url)
            },
            measureListMetrics: { apps in
                // One background pass over the whole list: the bundle-size walk
                // is the expensive measurement discovery deliberately skips, so
                // it runs detached off the main actor and streams its results
                // back in small chunks so the list fills in progressively.
                AsyncStream { continuation in
                    let task = Task.detached(priority: .utility) {
                        let fileManager = FileManager.default
                        // Flush a chunk every few apps so rows update in visible
                        // waves without re-sorting the list on every single app.
                        let chunkSize = 8
                        var sizes: [AppInfo.ID: Int64] = [:]
                        var dates: [AppInfo.ID: Date] = [:]
                        for app in apps {
                            if Task.isCancelled { break }
                            sizes[app.id] = DefaultAppDiscovery.bundleSize(at: app.bundleURL, fileManager: fileManager)
                            dates[app.id] = DefaultUnusedAppScanner.spotlightLastUsedDate(app)
                            if sizes.count >= chunkSize {
                                continuation.yield((sizes, dates))
                                sizes = [:]
                                dates = [:]
                            }
                        }
                        if !sizes.isEmpty { continuation.yield((sizes, dates)) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            recycle: { bundleURL, associatedURLs in
                try await Self.recycleViaWorkspace(
                    bundleURL: bundleURL,
                    associatedURLs: associatedURLs
                )
            },
            // recycleViaWorkspace already returns a RecycleOutcome.
            reinstallHelper: {
                await HelperRegistration.reregister()
                await HelperRegistration.openLoginItemsSettings()
            }
        )
    }

    /// Production recycle: move to Trash via `NSWorkspace`, then escalate
    /// anything the user couldn't move (a root-owned / App Store bundle) to
    /// the privileged helper. Wires the real side-effecting primitives into
    /// `recycleWithEscalation`.
    private static func recycleViaWorkspace(
        bundleURL: URL,
        associatedURLs: [URL]
    ) async throws -> RecycleOutcome {
        try await recycleWithEscalation(
            bundleURL: bundleURL,
            associatedURLs: associatedURLs,
            recycle: { urls in await workspaceRecycle(urls) },
            escalate: { paths in await escalateToHelper(paths) },
            // The snapshot walks the whole bundle tree — for an Xcode-class
            // app that's 100k+ files, which must never run on the main
            // actor where it would beach-ball the confirmation click.
            sizeFor: { urls in
                await Task.detached(priority: .userInitiated) {
                    sizes(for: urls)
                }.value
            },
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Pure orchestration of the recycle → privileged-escalation → byte-credit
    /// flow, with every side-effecting primitive injected so it can be unit
    /// tested without `NSWorkspace` or a live XPC helper.
    ///
    /// Steps:
    ///   1. Snapshot sizes *before* anything moves — a Trashed or deleted path
    ///      no longer stats, so we couldn't credit it afterwards.
    ///   2. Move everything via `recycle` (`NSWorkspace` → the user's Trash).
    ///      User-owned residue lands here and stays restorable.
    ///   3. Anything still on disk afterwards is a path the user lacked
    ///      permission to move — typically the root-owned `.app` bundle of an
    ///      App Store app. Escalate those to the privileged helper, which
    ///      removes them *permanently* (it cannot move to the user's Trash).
    ///   4. Credit bytes for every original item that no longer exists,
    ///      whether it was Trashed or permanently removed.
    ///   5. The `.app` bundle is the must-succeed item. If it survives both
    ///      passes the app is still installed, so throw rather than report a
    ///      false "Complete" and leave a stale row in the list. Associated-
    ///      file partial failures are tolerated — best-effort cleanup.
    static func recycleWithEscalation(
        bundleURL: URL,
        associatedURLs: [URL],
        recycle: (_ urls: [URL]) async -> (moved: Set<String>, error: Error?),
        escalate: (_ paths: [String]) async -> Error?,
        // `@Sendable` is load-bearing: a plain closure would inherit this
        // function's main-actor isolation and run the bundle walk on the
        // main thread anyway. Sendable + async makes the snapshot hop off.
        sizeFor: @Sendable (_ urls: [URL]) async -> [String: Int64],
        exists: (_ path: String) -> Bool
    ) async throws -> RecycleOutcome {
        let allURLs = [bundleURL] + associatedURLs
        let sizesByPath = await sizeFor(allURLs)

        let (moved, recycleError) = await recycle(allURLs)

        // Escalate only the *bundle* to the privileged helper for permanent
        // removal — never the associated files. The confirmation promised the
        // associated files would be moved to the Trash (restorable), so any
        // the user couldn't Trash are left in place best-effort rather than
        // permanently deleted behind the user's back.
        var escalateError: Error?
        if !moved.contains(bundleURL.path), exists(bundleURL.path) {
            escalateError = await escalate([bundleURL.path])
        }

        if exists(bundleURL.path) {
            throw escalateError ?? recycleError ?? bundleNotMovedError()
        }

        let bytesFreed = allURLs.reduce(Int64(0)) { sum, url in
            exists(url.path) ? sum : sum + (sizesByPath[url.path] ?? 0)
        }
        // The bundle was permanently removed (not Trashed) when NSWorkspace
        // didn't move it but it is now gone — i.e. the privileged helper
        // deleted it. This is the authoritative signal the completion screen
        // uses, rather than a pre-flight guess at App Store status.
        let bundlePermanentlyRemoved = !moved.contains(bundleURL.path)
            && !exists(bundleURL.path)
        return RecycleOutcome(
            bytesFreed: bytesFreed,
            bundlePermanentlyRemoved: bundlePermanentlyRemoved
        )
    }

    /// Bridges `NSWorkspace.recycle(_:completionHandler:)` (callback-based,
    /// returns a `[URL: URL]` map of original → Trash URLs) to an async call
    /// that reports the set of original paths successfully Trashed plus any
    /// batch-level error. `NSWorkspace.recycle` does NOT throw on partial
    /// failure — it Trashes what it can and reports an error only when the
    /// whole batch fails.
    private static func workspaceRecycle(
        _ urls: [URL]
    ) async -> (moved: Set<String>, error: Error?) {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { newURLs, error in
                let moved = Set(newURLs.keys.map { $0.path })
                continuation.resume(returning: (moved, error))
            }
        }
    }

    /// Sends `paths` to the privileged helper for permanent removal. Mirrors
    /// `SystemJunkDeleter`'s dual-resume guard: `NSXPCConnection` may fire the
    /// connection-level error handler *instead of* the reply block, so we arm
    /// both and let whichever lands first resolve the call.
    private static func escalateToHelper(_ paths: [String]) async -> Error? {
        await withCheckedContinuation { continuation in
            let resumer = HelperReplyResumer(continuation: continuation)
            let helper = HelperConnectionManager.shared.helper { error in
                resumer.resume(with: error)
            }
            guard let helper else {
                resumer.resume(with: HelperConnectionError.unavailable)
                return
            }
            helper.deleteFiles(paths) { replyError in
                resumer.resume(with: replyError)
            }
        }
    }

    private static func bundleNotMovedError() -> NSError {
        NSError(
            domain: "com.personal.VaderCleaner.AppUninstaller",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "The application bundle could not be moved to the Trash."
            ]
        )
    }

    /// Pre-recycle size snapshot keyed by absolute path. Directories sum
    /// their regular-file children; missing items contribute 0. `nonisolated`
    /// so the production wiring can run the walk on a detached task — it
    /// touches only `FileManager`, never view-model state.
    nonisolated static func sizes(for urls: [URL]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result[url.path] = 0
                continue
            }
            if !isDirectory.boolValue {
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber {
                    result[url.path] = size.int64Value
                } else {
                    result[url.path] = 0
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                result[url.path] = 0
                continue
            }
            var total: Int64 = 0
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true, let fileSize = values?.fileSize {
                    total += Int64(fileSize)
                }
            }
            result[url.path] = total
        }
        return result
    }
}

// MARK: - Once-only continuation resume

/// Wraps a `CheckedContinuation` so exactly one of the paths that may complete
/// a helper XPC call (reply block, connection error handler, "helper
/// unavailable" early return) actually resumes it — `CheckedContinuation`
/// traps on a second resume. Mirrors the `Resumer` used by `SystemJunkDeleter`
/// for the same dual-callback race.
private final class HelperReplyResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?

    init(continuation: CheckedContinuation<Error?, Never>) {
        self.continuation = continuation
    }

    func resume(with error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: error)
    }
}
