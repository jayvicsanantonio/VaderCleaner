// AppUninstallerViewModel.swift
// State machine and selection logic behind the App Uninstaller feature view — drives idle/loading/ready/uninstalling/complete transitions and routes the uninstall through an injected recycler.

import AppKit
import Foundation
import Observation
import os.log

/// Why an app was refused before anything was moved.
enum AppUninstallRefusal: LocalizedError {
    case appIsRunning(name: String)

    var errorDescription: String? {
        switch self {
        case .appIsRunning(let name):
            return String(
                localized: "\(name) is running. Quit it, then try again.",
                bundle: .module,
                comment: "Uninstall refusal for an app that is currently running."
            )
        }
    }
}

/// Drives the App Uninstaller feature view (load apps → select → uninstall → done).
///
/// Like `PrivacyViewModel` and `SystemJunkViewModel`, all collaborators are
/// injected as closures so unit tests can drive every transition without
/// touching real disk state. Production wiring lives in
/// `AppUninstallerViewModel.live()` below.
@MainActor
@Observable
public final class AppUninstallerViewModel {

    /// Which step of the flow generated a `.failed` phase, so the view can
    /// pick the right heading.
    public enum FailureStage: Equatable {
        case loading
        case uninstalling
    }

    /// Discrete phases the view binds to.
    public enum Phase: Equatable {
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
    public struct RecycleOutcome: Equatable, Sendable {
        let bytesFreed: Int64
        let bundlePermanentlyRemoved: Bool

        /// The memberwise initializer, written out because Swift only
        /// synthesizes an internal one and the app builds these across the
        /// module boundary.
        public init(bytesFreed: Int64, bundlePermanentlyRemoved: Bool) {
            self.bytesFreed = bytesFreed
            self.bundlePermanentlyRemoved = bundlePermanentlyRemoved
        }
    }

    public typealias Discover     = @Sendable (_ includingSystemApps: Bool) async throws -> [AppInfo]
    public typealias FindFiles    = @Sendable (_ bundleID: String) async -> [AssociatedFile]
    public typealias MeasureSize  = @Sendable (_ bundleURL: URL) async -> Int64
    /// Streaming bundle-size walk for the Applications Manager's uninstaller
    /// list: yields chunks of per-app sizes as the background pass measures
    /// them, so the list fills in progressively rather than snapping every row
    /// to its size only when the whole walk finishes. Size is the one expensive
    /// measurement discovery deliberately skips (last-opened date rides on
    /// `AppInfo` from discovery), which is why only it streams off the main
    /// actor. Each chunk maps `AppInfo.ID` to the measured byte size.
    public typealias MeasureListMetrics = @Sendable (_ apps: [AppInfo]) -> AsyncStream<[AppInfo.ID: Int64]>
    /// Recycler contract: takes the `.app` bundle URL and the associated
    /// file URLs separately so the production implementation can verify
    /// the bundle itself was moved (and not just the user-writable
    /// residue). Reports the bytes actually freed and whether the bundle
    /// was permanently removed rather than Trashed.
    public typealias Recycle      = @Sendable (_ bundleURL: URL, _ associatedURLs: [URL]) async throws -> RecycleOutcome
    /// Forces a clean re-registration of the privileged helper and points the
    /// user at the approval UI. Injected so tests don't touch `SMAppService`.
    public typealias ReinstallHelper = @Sendable () async -> Void
    /// Whether this exact copy of the app is running. Moving a running app's
    /// bundle leaves the process alive against files it can no longer find.
    public typealias AppIsRunning = @Sendable (_ app: AppInfo) -> Bool

    public private(set) var phase: Phase = .idle
    /// Apps the last batch couldn't remove. A batch that removed anything lands
    /// in `.complete`, so this is what keeps a partial failure visible.
    private(set) var batchFailedAppNames: [String] = []
    /// Apps uninstalled since the last load, so the panes that keep their own
    /// copy of the app list can drop them. Holds only what this view model
    /// removed: `forgetApps(_:)` doesn't add to it, or two panes telling each
    /// other about the same app would never settle.
    public private(set) var removedAppIDs: Set<AppInfo.ID> = []
    public private(set) var apps: [AppInfo] = []
    private(set) var selectedAppID: AppInfo.ID?
    private(set) var associatedFiles: [AssociatedFile] = []
    public private(set) var isLoadingAssociatedFiles: Bool = false
    /// Bundle size of the currently selected app, computed lazily on
    /// selection. `nil` until the per-app size measurement returns.
    public private(set) var selectedAppBundleSize: Int64?
    var includesSystemApps: Bool = false
    var searchQuery: String = ""

    /// Apps checked for the Applications Manager's batch uninstall, keyed by
    /// `AppInfo.ID`. Separate from `selectedAppID` (which drives the single-app
    /// associated-files inspector behind each row's chevron) so the multi-select
    /// list and the detail inspector don't fight over one selection.
    public private(set) var uninstallSelection: Set<AppInfo.ID> = []

    /// Session-scoped per-app bundle-size cache the Applications Manager's
    /// uninstaller list sorts and renders by. Populated by `loadListMetrics()`
    /// and retained for the session so reopening the manager reuses it instead
    /// of re-walking the disk. Observable so each row re-renders when its size
    /// lands. Last-opened date is not cached here — it rides on `AppInfo`.
    public private(set) var listSizes: [AppInfo.ID: Int64] = [:]
    /// Apps whose size has been measured, tracked separately from `listSizes`
    /// so a still-pending app is retried while a genuinely measured one is not.
    @ObservationIgnored private var measuredListMetricApps: Set<AppInfo.ID> = []
    /// Bumped once a metrics stream finishes so the manager's memoized list
    /// re-sorts into its final order. The per-chunk dictionary merges above
    /// already re-render each row's size/date as the values stream in; this
    /// gives the sort a single settle at the end rather than reordering the
    /// whole list on every chunk.
    public private(set) var listMetricsRevision: Int = 0
    /// Bumped by `refresh()`, which discards the measured sizes. The app roster
    /// usually comes back the same, so the manager keys its measuring task on
    /// this too, or nothing would measure them again.
    public private(set) var listMetricsEpoch: Int = 0

    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let findFiles: FindFiles
    @ObservationIgnored private let measureSize: MeasureSize
    @ObservationIgnored private let measureListMetrics: MeasureListMetrics
    @ObservationIgnored private let recycle: Recycle
    @ObservationIgnored private let reinstallHelperService: ReinstallHelper
    @ObservationIgnored private let appIsRunning: AppIsRunning
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

    public init(
        discover: @escaping Discover,
        findFiles: @escaping FindFiles,
        measureSize: @escaping MeasureSize = { _ in 0 },
        measureListMetrics: @escaping MeasureListMetrics = { _ in AsyncStream { $0.finish() } },
        recycle: @escaping Recycle,
        reinstallHelper: @escaping ReinstallHelper = {},
        appIsRunning: @escaping AppIsRunning = { _ in false }
    ) {
        self.discover = discover
        self.findFiles = findFiles
        self.measureSize = measureSize
        self.measureListMetrics = measureListMetrics
        self.recycle = recycle
        self.reinstallHelperService = reinstallHelper
        self.appIsRunning = appIsRunning
    }

    // MARK: - Public surface

    /// Convenience for the view layer — the currently selected `AppInfo`.
    public var selectedApp: AppInfo? {
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
    public var totalReclaimableSize: Int64 {
        guard selectedApp != nil else { return 0 }
        let associated = associatedFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return (selectedAppBundleSize ?? 0) + associated
    }

    /// Associated files for the selected app grouped by category, in the
    /// stable declaration order of `AssociatedFileCategory.allCases`. The
    /// view renders one section per category.
    public var associatedFilesByCategory: [(AssociatedFileCategory, [AssociatedFile])] {
        var bucketed: [AssociatedFileCategory: [AssociatedFile]] = [:]
        for file in associatedFiles {
            bucketed[file.category, default: []].append(file)
        }
        return AssociatedFileCategory.allCases.compactMap { category in
            guard let entries = bucketed[category], !entries.isEmpty else { return nil }
            return (category, entries)
        }
    }

    /// What the manager's result banner should say about the last uninstall,
    /// or `nil` when there is nothing to report.
    public var notice: ManagerNotice? {
        switch phase {
        case .complete(let bytesFreed, let permanentRemoval):
            let freed = formattedFileBytes(bytesFreed)
            if !batchFailedAppNames.isEmpty {
                let names = ApplicationsManagerModel.nameSummary(batchFailedAppNames)
                return ManagerNotice(
                    message: String(
                        localized: "Freed \(freed), but couldn't uninstall \(names). Check that they aren't running, then try again.",
                        bundle: .module,
                        comment: "Result banner when a batch uninstall partly failed; freed size and app names."
                    ),
                    isError: true
                )
            }
            return ManagerNotice(
                message: permanentRemoval
                    ? String(
                        localized: "Freed \(freed). An app that couldn't go to the Trash was permanently deleted and can't be restored.",
                        bundle: .module,
                        comment: "Result banner when an uninstall permanently deleted an app; freed size."
                    )
                    : String(
                        localized: "Moved to the Trash. Freed \(freed).",
                        bundle: .module,
                        comment: "Result banner after a successful uninstall; freed size."
                    ),
                isError: false
            )
        case .failed(.uninstalling, let message, let helperConnectionIssue):
            return ManagerNotice(
                message: message,
                isError: true,
                offersHelperReinstall: helperConnectionIssue
            )
        default:
            return nil
        }
    }

    /// The discovery failure's message, when the app list couldn't be loaded.
    /// An empty list here means nothing about what's installed, so the pane
    /// shows this rather than its all-clear empty state.
    public var loadFailureMessage: String? {
        guard case .failed(.loading, let message, _) = phase else { return nil }
        return message
    }

    /// The apps the Uninstaller may offer. VaderCleaner is left out: trashing
    /// the running app, helper included, isn't an uninstall anyone can finish
    /// from inside it.
    nonisolated static func uninstallableApps(_ apps: [AppInfo], selfBundleID: String?) -> [AppInfo] {
        apps.filter { $0.bundleID != selfBundleID }
    }

    /// Whether another installed copy shares `app`'s bundle ID. Support files
    /// are named for the bundle ID, so they belong to every copy: they go only
    /// with the last one. `leaving` names copies on their way out in this batch.
    private func hasAnotherCopy(of app: AppInfo, leaving: Set<AppInfo.ID> = []) -> Bool {
        apps.contains {
            $0.bundleID == app.bundleID && $0.id != app.id && !leaving.contains($0.id)
        }
    }

    // MARK: - Actions

    /// Initial load — populates `apps` and lands in `.ready` (or `.failed`).
    public func loadApps() async {
        let generation = beginLoad()
        phase = .loading
        let includes = includesSystemApps
        do {
            let result = try await discover(includes)
            guard self.loadGeneration == generation else { return }
            self.apps = result
            self.uninstallSelection.formIntersection(result.map(\.id))
            self.removedAppIDs = []
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

    /// Reloads the app list and throws away everything measured from the old
    /// one. An app can change size or contents without its path changing, so
    /// the session caches are only good until something asks for fresh data.
    public func refresh() async {
        measuredListMetricApps = []
        associatedFilesCache = [:]
        bundleSizeCache = [:]
        listMetricsEpoch &+= 1
        await loadApps()
    }

    /// Reloads the app list with the current `includesSystemApps` setting.
    /// Called by the view when the user flips the toggle so the visible
    /// list reflects the new filter immediately.
    func reloadApps() async {
        await loadApps()
    }

    /// Measures bundle size for every app not already in the `listSizes` cache,
    /// merging each streamed chunk as it arrives so rows fill in progressively
    /// instead of all at once when the whole walk finishes. Idempotent: apps
    /// measured earlier in the session are skipped, so the expensive disk walk
    /// runs once per app and reopening the manager reuses the cache. A no-op
    /// when nothing is pending — the revision only bumps when new sizes land.
    public func loadListMetrics() async {
        let pending = apps.filter { !measuredListMetricApps.contains($0.id) }
        guard !pending.isEmpty else { return }
        // Merge each chunk rather than replace so apps already measured keep
        // their sizes, and each row updates the moment its size streams in.
        //
        // An app is marked measured only once its size actually arrives. The
        // stream is driven by a `.task(id:)` that is cancelled whenever the app
        // list changes — an uninstall, say — and a cancelled walk ends the loop
        // early. Marking the whole pending set here would record apps the walk
        // never reached, and the guard above would then skip them for the rest
        // of the session, leaving their rows permanently sizeless.
        var landed = false
        for await chunk in measureListMetrics(pending) {
            listSizes.merge(chunk) { _, new in new }
            measuredListMetricApps.formUnion(chunk.keys)
            landed = true
        }
        guard landed else { return }
        listMetricsRevision &+= 1
    }

    /// Select an app by ID. Drives an async associated-files lookup AND
    /// a deferred bundle-size measurement in parallel, publishing
    /// `associatedFiles` and `selectedAppBundleSize` independently as
    /// each one finishes. A second `select(...)` before the first
    /// finishes cancels the older lookups so the right-hand panel can't
    /// flash stale rows from a previous selection.
    public func select(_ appID: AppInfo.ID?) {
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

        let filesAreShared = hasAnotherCopy(of: app)
        if filesAreShared {
            // Another copy still needs these files, so none are on offer.
            associatedFiles = []
            isLoadingAssociatedFiles = false
        } else if let cachedFiles = associatedFilesCache[appID] {
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
        let needsFiles = !filesAreShared && associatedFilesCache[appID] == nil
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
    /// and leave residual user data behind — and while a batch is running,
    /// which owns the phase and may be working through this same app.
    public var canUninstallSelectedApp: Bool {
        selectedApp != nil && !isLoadingAssociatedFiles && phase != .uninstalling
    }

    /// Uninstall the currently-selected app. Routes the bundle URL plus
    /// every associated file URL through the injected recycler. A no-op
    /// when nothing is selected or when the associated-files scan is
    /// still in flight — confirming early would Trash only the bundle
    /// and leave residual user data behind.
    public func uninstall() async {
        guard let app = selectedApp, canUninstallSelectedApp else { return }
        batchFailedAppNames = []
        guard !appIsRunning(app) else {
            phase = .failed(stage: .uninstalling,
                            message: AppUninstallRefusal.appIsRunning(name: app.name).localizedDescription,
                            helperConnectionIssue: false)
            return
        }
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
            forgetApps([app.id])
            removedAppIDs.insert(app.id)
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
    public func reinstallHelper() async {
        await reinstallHelperService()
        await loadApps()
    }

    /// Returns the VM to `.ready` after a complete / failed phase so the
    /// user can pick another app to uninstall without restarting the
    /// discovery scan.
    public func dismissResult() {
        batchFailedAppNames = []
        phase = .ready
    }

    /// Everything the view model remembers about apps that have been removed:
    /// the row, its checkbox, its measured size, and the inspector if it was
    /// showing one. A stale selection entry would keep the footer's Uninstall
    /// enabled with nothing behind it; a stale size would be reused verbatim
    /// if the app came back.
    public func forgetApps(_ ids: Set<AppInfo.ID>) {
        apps.removeAll { ids.contains($0.id) }
        uninstallSelection.subtract(ids)
        measuredListMetricApps.subtract(ids)
        for id in ids {
            listSizes.removeValue(forKey: id)
            associatedFilesCache.removeValue(forKey: id)
            bundleSizeCache.removeValue(forKey: id)
        }
        if let selected = selectedAppID, ids.contains(selected) {
            selectedAppID = nil
            associatedFiles = []
            selectedAppBundleSize = nil
        }
    }

    // MARK: - Multi-select (Applications Manager)

    /// Whether `id` is checked for the batch uninstall.
    public func isInUninstallSelection(_ id: AppInfo.ID) -> Bool {
        uninstallSelection.contains(id)
    }

    /// Toggle one app's checkbox in the batch-uninstall selection.
    public func toggleUninstallSelection(_ id: AppInfo.ID) {
        if uninstallSelection.contains(id) {
            uninstallSelection.remove(id)
        } else {
            uninstallSelection.insert(id)
        }
    }

    /// Check exactly the supplied apps (e.g. the rows currently in view after a
    /// facet filter). Single write so SwiftUI observes one publish.
    public func selectAllForUninstall(_ ids: [AppInfo.ID]) {
        uninstallSelection = Set(ids)
    }

    /// Uncheck everything — single-write counterpart to `selectAllForUninstall`.
    public func clearUninstallSelection() {
        uninstallSelection = []
    }

    /// Whether the footer's Uninstall action should be enabled: something is
    /// checked and no batch is already running.
    public var canUninstallSelection: Bool {
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
    public func uninstallSelected() async {
        let targets = apps.filter { uninstallSelection.contains($0.id) }
        guard !targets.isEmpty else { return }
        if case .uninstalling = phase { return }

        phase = .uninstalling
        batchFailedAppNames = []
        var totalBytesFreed: Int64 = 0
        var anyPermanentRemoval = false
        var removedIDs: Set<AppInfo.ID> = []
        var failedNames: [String] = []
        var lastError: Error?

        for app in targets {
            guard !appIsRunning(app) else {
                failedNames.append(app.name)
                lastError = AppUninstallRefusal.appIsRunning(name: app.name)
                continue
            }
            let associatedURLs = hasAnotherCopy(of: app, leaving: removedIDs)
                ? []
                : await findFiles(app.bundleID).map { $0.url }
            do {
                let outcome = try await recycle(app.bundleURL, associatedURLs)
                totalBytesFreed += outcome.bytesFreed
                anyPermanentRemoval = anyPermanentRemoval || outcome.bundlePermanentlyRemoved
                removedIDs.insert(app.id)
            } catch {
                // Privacy: errors may include user-specific paths.
                log.error("Batch uninstall of \(app.bundleID, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                failedNames.append(app.name)
                lastError = error
            }
        }

        forgetApps(removedIDs)
        removedAppIDs.formUnion(removedIDs)
        batchFailedAppNames = failedNames

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
    public static func live(exclusions: ExclusionsStore) -> AppUninstallerViewModel {
        let discovery = DefaultAppDiscovery()
        return AppUninstallerViewModel(
            discover: { includingSystemApps in
                uninstallableApps(
                    try await discovery.installedApps(includingSystemApps: includingSystemApps),
                    selfBundleID: Bundle.main.bundleIdentifier
                )
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
                        for app in apps {
                            if Task.isCancelled { break }
                            sizes[app.id] = DefaultAppDiscovery.bundleSize(at: app.bundleURL, fileManager: fileManager)
                            if sizes.count >= chunkSize {
                                continuation.yield(sizes)
                                sizes = [:]
                            }
                        }
                        if !sizes.isEmpty { continuation.yield(sizes) }
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
            },
            // By bundle URL, not just ID: quitting one copy shouldn't be a
            // condition of removing another.
            appIsRunning: { app in
                NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains {
                    $0.bundleURL?.standardizedFileURL == app.bundleURL.standardizedFileURL
                }
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
            exists: { FileManager.default.fileExists(atPath: $0) },
            unloadLaunchAgents: { urls in
                await Task.detached(priority: .userInitiated) {
                    for url in urls {
                        // Not `-w`: this isn't disabling the job, and if the
                        // move fails the agent should come back at next login.
                        try? LaunchAgentManager.defaultLaunchctl(["unload", url.path])
                    }
                }.value
            }
        )
    }

    /// Pure orchestration of the recycle → privileged-escalation → byte-credit
    /// flow, with every side-effecting primitive injected so it can be unit
    /// tested without `NSWorkspace` or a live XPC helper.
    ///
    /// Steps:
    ///   1. Snapshot sizes *before* anything moves — a Trashed or deleted path
    ///      no longer stats, so we couldn't credit it afterwards. Launch agents
    ///      are unloaded here too: a job launchd still holds keeps running
    ///      after its plist has gone. Daemons are out of reach, since unloading
    ///      one needs root; they stop at the next restart.
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
        exists: (_ path: String) -> Bool,
        unloadLaunchAgents: (_ plists: [URL]) async -> Void = { _ in }
    ) async throws -> RecycleOutcome {
        let allURLs = [bundleURL] + associatedURLs
        let sizesByPath = await sizeFor(allURLs)

        let launchAgents = associatedURLs.filter {
            $0.deletingLastPathComponent().lastPathComponent == "LaunchAgents"
        }
        if !launchAgents.isEmpty {
            await unloadLaunchAgents(launchAgents)
        }

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

    /// Sends `paths` to the privileged helper for permanent removal. See
    /// `HelperCall` for the dual reply/error paths — `NSXPCConnection` may
    /// fire the connection-level error handler *instead of* the reply block —
    /// and the watchdog that bounds a helper which never answers.
    private static func escalateToHelper(_ paths: [String]) async -> Error? {
        await HelperCall.perform(
            helperProvider: SystemJunkDeleter.defaultHelperProvider
        ) { helper, reply in
            helper.deleteFiles(paths, reply: reply)
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
        let fileManager = FileManager.default
        var result: [String: Int64] = [:]
        for url in urls {
            result[url.path] = PathSizer.size(at: url, fileManager: fileManager)
        }
        return result
    }
}
