// ApplicationsViewModel.swift
// Scannable aggregator behind the Applications section — discovers installed apps and checks for updates, then drives the post-scan dashboard grid.

import AppKit
import Foundation
import Observation
import os.log

/// One aggregated Applications scan result, holding the discovered apps and the
/// available updates so the dashboard grid can render a card per finding. Phase
/// 0 carries the installed apps (Manage My Applications card) and the available
/// updates (Updates card); later phases extend this payload with unused apps,
/// unsupported apps, leftovers, and installation files.
struct ApplicationsScanResult: Equatable {
    // `var` so the post-delete rebuilds can copy-and-mutate a single field
    // without re-spelling the whole aggregate (and risking a dropped field).
    var installedApps: [AppInfo]
    var availableUpdates: [UpdateInfo]
    var installationFiles: [InstallationFile]
    var unsupportedApps: [UnsupportedApp]
    var unusedApps: [UnusedApp]
    var leftovers: [LeftoverGroup]

    /// "We've found N apps on your Mac." headline figure.
    var installedCount: Int { installedApps.count }
    /// Updates card count.
    var updatesCount: Int { availableUpdates.count }
    /// Installation Files card count.
    var installationFilesCount: Int { installationFiles.count }
    /// Sum of the leftover installers' sizes — the Installation Files card's
    /// "reclaimable" figure.
    var installationFilesTotalBytes: Int64 {
        installationFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
    /// Unsupported Applications card count.
    var unsupportedAppsCount: Int { unsupportedApps.count }
    /// Unused Applications card count.
    var unusedAppsCount: Int { unusedApps.count }
    /// App Leftovers card count (one per orphaned bundle ID).
    var leftoversCount: Int { leftovers.count }
    /// Sum of every leftover group's size — the Leftovers card's reclaimable
    /// figure.
    var leftoversTotalBytes: Int64 {
        leftovers.reduce(Int64(0)) { $0 + $1.totalBytes }
    }

    /// A category the dashboard can recommend acting on. The grid renders one
    /// card per recommendation, in this declaration order — which is the
    /// severity / actionability ranking, so the hero (first) card is always the
    /// finding that most warrants attention: apps that can't run, then stale
    /// apps, then available updates, then orphaned files and installer cruft.
    enum Recommendation: CaseIterable {
        case unsupported
        case unused
        case updates
        case leftovers
        case installationFiles
    }

    /// The categories that currently have findings, ranked by severity (the
    /// `Recommendation` declaration order). The full installed-app list is
    /// deliberately excluded — it lives under "Manage My Applications", not as a
    /// cleanup card.
    var recommendations: [Recommendation] {
        Recommendation.allCases.filter { recommendation in
            switch recommendation {
            case .unsupported:       return unsupportedAppsCount > 0
            case .unused:            return unusedAppsCount > 0
            case .updates:           return updatesCount > 0
            case .leftovers:         return leftoversCount > 0
            case .installationFiles: return installationFilesCount > 0
            }
        }
    }

    /// Reclaimable size for a recommendation, used to rank the space-based
    /// findings; `0` for the count-based ones (apps that need review rather than
    /// bytes to free).
    private func reclaimableBytes(for recommendation: Recommendation) -> Int64 {
        switch recommendation {
        case .leftovers:         return leftoversTotalBytes
        case .installationFiles: return installationFilesTotalBytes
        case .unsupported, .unused, .updates: return 0
        }
    }

    /// The ranked 2–4 cards the dashboard shows: findings that need review lead,
    /// then the space-based findings by how much they free (capped at four),
    /// backfilled with reassurance cards when a scan finds fewer than two.
    func recommendedTiles() -> [ApplicationsDashboardTile] {
        let real = recommendations.map { recommendation in
            RankedTile(payload: ApplicationsDashboardTile.recommendation(recommendation),
                       urgency: recommendation.urgency,
                       reclaimableBytes: reclaimableBytes(for: recommendation))
        }
        let reassurance = ApplicationsDashboardTile.reassurancePool.map { content in
            RankedTile(payload: ApplicationsDashboardTile.reassurance(content),
                       urgency: .reassurance,
                       reclaimableBytes: 0)
        }
        return SectionRecommendationSelector.select(real: real, reassurance: reassurance)
    }
}

/// One card on the Applications dashboard: a cleanup recommendation, or an "all
/// good" reassurance card used to backfill the grid to its minimum count.
enum ApplicationsDashboardTile: Identifiable {
    case recommendation(ApplicationsScanResult.Recommendation)
    case reassurance(ReassuranceContent)

    var id: String {
        switch self {
        case .recommendation(let recommendation): return "recommendation.\(recommendation)"
        case .reassurance(let content):           return "reassurance.\(content.id)"
        }
    }

    /// Ordered pool of "all good" cards, drawn from in order when a scan finds
    /// fewer than two cleanup categories so backfilling never repeats a card.
    static let reassurancePool: [ReassuranceContent] = [
        ReassuranceContent(
            id: "applications.allClear",
            title: String(localized: "Apps Look Healthy", comment: "Applications reassurance card title."),
            detail: String(
                localized: "No unused or unsupported apps, updates, leftovers, or installer files to review.",
                comment: "Applications reassurance card detail."
            ),
            icon: "checkmark.seal"
        ),
        ReassuranceContent(
            id: "applications.manage",
            title: String(localized: "Manage Anytime", comment: "Applications reassurance card title."),
            detail: String(
                localized: "Open Manage My Applications to browse everything you have installed.",
                comment: "Applications reassurance card detail."
            ),
            icon: "square.grid.2x2"
        ),
    ]
}

extension ApplicationsScanResult.Recommendation {
    /// How strongly this finding demands attention. Apps that need review lead
    /// the space-based cruft, matching the section's severity ordering.
    var urgency: RecommendationUrgency {
        switch self {
        case .unsupported, .unused, .updates: return .attention
        case .leftovers, .installationFiles:  return .space
        }
    }
}

/// Drives the Applications feature view (scan → results). Collaborators are
/// injected as closures so unit tests can exercise every transition without
/// touching the real filesystem or network. Production wiring lives in
/// `ApplicationsViewModel.live()`.
///
/// This view-model is purely additive — it produces the post-scan dashboard
/// metrics. The actual uninstall and update side-effects stay owned by the
/// existing `AppUninstallerViewModel` / `AppUpdaterViewModel`, which the
/// dashboard reuses unchanged as its detail screens.
@MainActor
@Observable
final class ApplicationsViewModel {

    /// Discrete phases the view binds to. The happy path is
    /// `idle → scanning → results`; `failed` carries a message to surface.
    enum Phase: Equatable {
        case idle
        case scanning
        case results(ApplicationsScanResult)
        case failed(message: String)
    }

    /// Installed-app discovery source. Throwing: a failed discovery fails the
    /// whole scan, mirroring `AppUninstallerViewModel.loadApps`.
    typealias DiscoverApps = @Sendable () async throws -> [AppInfo]
    /// Update-check source. Non-throwing and best-effort: a network blip yields
    /// `[]` rather than sinking an otherwise-useful scan (the production wiring
    /// swallows per-app failures), matching the Smart Scan Applications tile.
    typealias CheckUpdates = @Sendable ([AppInfo]) async -> [UpdateInfo]
    /// Installation-file scan source. Non-throwing and best-effort, same
    /// partial-degradation contract as `CheckUpdates`.
    typealias ScanInstallationFiles = @Sendable () async -> [InstallationFile]
    /// Unsupported-app scan source over the discovered apps. Non-throwing and
    /// best-effort, same partial-degradation contract as `CheckUpdates`.
    typealias ScanUnsupportedApps = @Sendable ([AppInfo]) async -> [UnsupportedApp]
    /// Unused-app scan source over the discovered apps. Non-throwing and
    /// best-effort, same partial-degradation contract as `CheckUpdates`.
    typealias ScanUnusedApps = @Sendable ([AppInfo]) async -> [UnusedApp]
    /// Leftover scan source. Takes the installed bundle IDs so the scan can
    /// tell orphaned support files from installed apps'. Non-throwing and
    /// best-effort, same partial-degradation contract as `CheckUpdates`.
    typealias ScanLeftovers = @Sendable (Set<String>) async -> [LeftoverGroup]
    /// Moves the given files to the Trash and returns the set of URLs actually
    /// recycled. Partial success is the norm (a locked file must not abort the
    /// batch), so the return is the success set — mirroring
    /// `MyClutterViewModel`'s deleter.
    typealias RecycleFiles = @Sendable ([URL]) async -> Set<URL>

    private(set) var phase: Phase = .idle

    /// Per-file gate for the Installation Files review screen, keyed by URL.
    /// Seeded *empty* — removal is destructive, so the user opts each installer
    /// in explicitly, matching `MyClutterViewModel`.
    private(set) var installationFileSelection: Set<URL> = []
    /// True while a recycle batch is in flight, so the review screen can show a
    /// spinner and disable its Remove button.
    private(set) var isRemovingInstallationFiles = false

    /// Per-app gate for the Unsupported Applications review screen, keyed by the
    /// app's bundle URL. Seeded *empty* — removal is destructive and opt-in.
    private(set) var unsupportedAppSelection: Set<URL> = []
    /// True while an unsupported-app recycle batch is in flight.
    private(set) var isRemovingUnsupportedApps = false

    /// Per-app gate for the Unused Applications review screen, keyed by the
    /// app's bundle URL. Seeded *empty* — removal is destructive and opt-in.
    private(set) var unusedAppSelection: Set<URL> = []
    /// True while an unused-app recycle batch is in flight.
    private(set) var isRemovingUnusedApps = false

    /// Per-group gate for the App Leftovers review screen, keyed by the
    /// orphaned bundle ID. Seeded *empty* — removal is destructive and opt-in.
    private(set) var leftoverSelection: Set<String> = []
    /// True while a leftover recycle batch is in flight.
    private(set) var isRemovingLeftovers = false

    @ObservationIgnored private let discoverApps: DiscoverApps
    @ObservationIgnored private let checkUpdates: CheckUpdates
    @ObservationIgnored private let scanInstallationFiles: ScanInstallationFiles
    @ObservationIgnored private let scanUnsupportedApps: ScanUnsupportedApps
    @ObservationIgnored private let scanUnusedApps: ScanUnusedApps
    @ObservationIgnored private let scanLeftovers: ScanLeftovers
    @ObservationIgnored private let recycleFiles: RecycleFiles
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "ApplicationsViewModel")

    /// Incremented at the start of every scan so a result that resolves after a
    /// newer scan (or a `reset()`) began is dropped instead of overwriting it.
    @ObservationIgnored private var scanGeneration = 0

    init(
        discoverApps: @escaping DiscoverApps,
        checkUpdates: @escaping CheckUpdates,
        scanInstallationFiles: @escaping ScanInstallationFiles,
        scanUnsupportedApps: @escaping ScanUnsupportedApps,
        scanUnusedApps: @escaping ScanUnusedApps,
        scanLeftovers: @escaping ScanLeftovers,
        recycleFiles: @escaping RecycleFiles
    ) {
        self.discoverApps = discoverApps
        self.checkUpdates = checkUpdates
        self.scanInstallationFiles = scanInstallationFiles
        self.scanUnsupportedApps = scanUnsupportedApps
        self.scanUnusedApps = scanUnusedApps
        self.scanLeftovers = scanLeftovers
        self.recycleFiles = recycleFiles
    }

    // MARK: - Scan

    /// Discovers installed apps, then checks each for an available update, and
    /// lands `.results` (or `.failed` if discovery throws). Re-entrant calls
    /// while a scan is already in flight are ignored — the guard is read
    /// synchronously before the first `await`, so it is reliable under
    /// `@MainActor`.
    func scan() async {
        switch phase {
        case .scanning:
            return
        case .idle, .results, .failed:
            break
        }

        phase = .scanning
        scanGeneration &+= 1
        let generation = scanGeneration
        installationFileSelection = []
        unsupportedAppSelection = []
        unusedAppSelection = []
        leftoverSelection = []

        do {
            // The installer scan is independent of app discovery, so run it
            // concurrently with the discover → update-check chain.
            async let installersAsync = scanInstallationFiles()
            let apps = try await discoverApps()
            // The update check and the per-app scans all need the discovered
            // apps, so fan them out concurrently once they're known. The
            // leftover scan needs the installed bundle IDs to tell orphans
            // from installed apps' support files.
            let installedBundleIDs = Set(apps.map(\.bundleID))
            async let updatesAsync = checkUpdates(apps)
            async let unsupportedAsync = scanUnsupportedApps(apps)
            async let unusedAsync = scanUnusedApps(apps)
            async let leftoversAsync = scanLeftovers(installedBundleIDs)
            let installers = await installersAsync
            let updates = await updatesAsync
            let unsupported = await unsupportedAsync
            let unused = await unusedAsync
            let leftovers = await leftoversAsync
            guard scanGeneration == generation else { return }
            phase = .results(ApplicationsScanResult(
                installedApps: apps,
                availableUpdates: updates,
                installationFiles: installers,
                unsupportedApps: unsupported,
                unusedApps: unused,
                leftovers: leftovers
            ))
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("Applications scan failed: \(String(describing: error), privacy: .private)")
            guard scanGeneration == generation else { return }
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Returns to idle from a terminal phase so the user can start over from
    /// the intro screen.
    func reset() {
        phase = .idle
        installationFileSelection = []
        unsupportedAppSelection = []
        unusedAppSelection = []
        leftoverSelection = []
    }

    // MARK: - Installation files selection

    func isInstallationFileSelected(_ file: InstallationFile) -> Bool {
        installationFileSelection.contains(file.url)
    }

    func toggleInstallationFile(_ file: InstallationFile) {
        if installationFileSelection.contains(file.url) {
            installationFileSelection.remove(file.url)
        } else {
            installationFileSelection.insert(file.url)
        }
    }

    /// Opt every found installer in for removal in one write to the selection
    /// set, so SwiftUI observes a single publish instead of N.
    func selectAllInstallationFiles() {
        guard case .results(let result) = phase else { return }
        installationFileSelection = Set(result.installationFiles.map(\.url))
    }

    /// Opt every installer back out — single-write counterpart to
    /// `selectAllInstallationFiles()`.
    func clearInstallationFileSelection() {
        installationFileSelection = []
    }

    /// Whether a Remove press would actually recycle anything right now.
    var canRemoveInstallationFiles: Bool {
        !installationFileSelection.isEmpty && !isRemovingInstallationFiles
    }

    // MARK: - Installation files removal

    /// Moves the selected installers to the Trash and rebuilds the results
    /// payload with the survivors, so the dashboard card count and the review
    /// list both reflect what was actually removed. A no-op unless results are
    /// showing and at least one installer is selected.
    func deleteSelectedInstallationFiles() async {
        guard case .results(let result) = phase else { return }
        let targets = result.installationFiles.filter {
            installationFileSelection.contains($0.url)
        }
        guard !targets.isEmpty, !isRemovingInstallationFiles else { return }

        isRemovingInstallationFiles = true
        let removed = await recycleFiles(targets.map(\.url))
        isRemovingInstallationFiles = false

        // The recycle hop is async; only rewrite the payload if we are still
        // showing the same kind of results (a `reset()` / rescan during the
        // batch supersedes it).
        guard case .results(var current) = phase else { return }
        current.installationFiles.removeAll { removed.contains($0.url) }
        phase = .results(current)
        installationFileSelection.subtract(removed)
    }

    // MARK: - Unsupported apps selection

    func isUnsupportedAppSelected(_ entry: UnsupportedApp) -> Bool {
        unsupportedAppSelection.contains(entry.app.bundleURL)
    }

    func toggleUnsupportedApp(_ entry: UnsupportedApp) {
        if unsupportedAppSelection.contains(entry.app.bundleURL) {
            unsupportedAppSelection.remove(entry.app.bundleURL)
        } else {
            unsupportedAppSelection.insert(entry.app.bundleURL)
        }
    }

    func selectAllUnsupportedApps() {
        guard case .results(let result) = phase else { return }
        unsupportedAppSelection = Set(result.unsupportedApps.map(\.app.bundleURL))
    }

    func clearUnsupportedAppSelection() {
        unsupportedAppSelection = []
    }

    /// Whether a Remove press would actually recycle anything right now.
    var canRemoveUnsupportedApps: Bool {
        !unsupportedAppSelection.isEmpty && !isRemovingUnsupportedApps
    }

    // MARK: - Unsupported apps removal

    /// Moves the selected unsupported app bundles to the Trash and rebuilds the
    /// results payload with the survivors. Reuses the same recycle path as the
    /// installation files — only the app `.app` bundle is moved here; full
    /// associated-file cleanup remains available via Manage (the uninstaller).
    /// A no-op unless results are showing and at least one app is selected.
    func deleteSelectedUnsupportedApps() async {
        guard case .results(let result) = phase else { return }
        let targets = result.unsupportedApps.filter {
            unsupportedAppSelection.contains($0.app.bundleURL)
        }
        guard !targets.isEmpty, !isRemovingUnsupportedApps else { return }

        isRemovingUnsupportedApps = true
        let removed = await recycleFiles(targets.map(\.app.bundleURL))
        isRemovingUnsupportedApps = false

        guard case .results(var current) = phase else { return }
        current.unsupportedApps.removeAll { removed.contains($0.app.bundleURL) }
        phase = .results(current)
        unsupportedAppSelection.subtract(removed)
    }

    // MARK: - Unused apps selection

    func isUnusedAppSelected(_ entry: UnusedApp) -> Bool {
        unusedAppSelection.contains(entry.app.bundleURL)
    }

    func toggleUnusedApp(_ entry: UnusedApp) {
        if unusedAppSelection.contains(entry.app.bundleURL) {
            unusedAppSelection.remove(entry.app.bundleURL)
        } else {
            unusedAppSelection.insert(entry.app.bundleURL)
        }
    }

    func selectAllUnusedApps() {
        guard case .results(let result) = phase else { return }
        unusedAppSelection = Set(result.unusedApps.map(\.app.bundleURL))
    }

    func clearUnusedAppSelection() {
        unusedAppSelection = []
    }

    /// Whether a Remove press would actually recycle anything right now.
    var canRemoveUnusedApps: Bool {
        !unusedAppSelection.isEmpty && !isRemovingUnusedApps
    }

    // MARK: - Unused apps removal

    /// Moves the selected unused app bundles to the Trash and rebuilds the
    /// results payload with the survivors. Like the unsupported path, only the
    /// `.app` bundle is moved here; full associated-file cleanup remains
    /// available via Manage (the uninstaller). A no-op unless results are
    /// showing and at least one app is selected.
    func deleteSelectedUnusedApps() async {
        guard case .results(let result) = phase else { return }
        let targets = result.unusedApps.filter {
            unusedAppSelection.contains($0.app.bundleURL)
        }
        guard !targets.isEmpty, !isRemovingUnusedApps else { return }

        isRemovingUnusedApps = true
        let removed = await recycleFiles(targets.map(\.app.bundleURL))
        isRemovingUnusedApps = false

        guard case .results(var current) = phase else { return }
        current.unusedApps.removeAll { removed.contains($0.app.bundleURL) }
        phase = .results(current)
        unusedAppSelection.subtract(removed)
    }

    // MARK: - Leftovers selection

    func isLeftoverSelected(_ group: LeftoverGroup) -> Bool {
        leftoverSelection.contains(group.bundleID)
    }

    func toggleLeftover(_ group: LeftoverGroup) {
        if leftoverSelection.contains(group.bundleID) {
            leftoverSelection.remove(group.bundleID)
        } else {
            leftoverSelection.insert(group.bundleID)
        }
    }

    func selectAllLeftovers() {
        guard case .results(let result) = phase else { return }
        leftoverSelection = Set(result.leftovers.map(\.bundleID))
    }

    func clearLeftoverSelection() {
        leftoverSelection = []
    }

    /// Whether a Remove press would actually recycle anything right now.
    var canRemoveLeftovers: Bool {
        !leftoverSelection.isEmpty && !isRemovingLeftovers
    }

    // MARK: - Leftovers removal

    /// Moves every file in the selected leftover groups to the Trash and
    /// rebuilds the payload: a group whose files were all recycled is dropped;
    /// a partially-recycled group keeps its surviving files (so the user can
    /// retry). A no-op unless results are showing and at least one group is
    /// selected.
    func deleteSelectedLeftovers() async {
        guard case .results(let result) = phase else { return }
        let targets = result.leftovers.filter { leftoverSelection.contains($0.bundleID) }
        guard !targets.isEmpty, !isRemovingLeftovers else { return }

        isRemovingLeftovers = true
        let removed = await recycleFiles(targets.flatMap { $0.urls })
        isRemovingLeftovers = false

        guard case .results(var current) = phase else { return }
        current.leftovers = current.leftovers.compactMap { group in
            let survivingURLs = group.urls.filter { !removed.contains($0) }
            if survivingURLs.isEmpty { return nil }
            if survivingURLs.count == group.urls.count { return group }
            // Some files moved, some didn't — keep the group with what's left.
            return LeftoverGroup(
                bundleID: group.bundleID,
                displayName: group.displayName,
                urls: survivingURLs,
                totalBytes: group.totalBytes
            )
        }
        phase = .results(current)
        // Drop selections for groups that fully disappeared.
        leftoverSelection = leftoverSelection.intersection(Set(current.leftovers.map(\.bundleID)))
    }
}

// MARK: - Production wiring

extension ApplicationsViewModel {

    /// Builds a view-model wired to the real `DefaultAppDiscovery` and
    /// `UpdateProbe.live()` — the same collaborators `AppUpdaterViewModel.live`
    /// uses, so the dashboard's update count matches the updater list it
    /// opens.
    @MainActor
    static func live() -> ApplicationsViewModel {
        let discovery = DefaultAppDiscovery()
        let probe = UpdateProbe.live()
        let installerScanner = DefaultInstallationFileScanner()
        let unsupportedScanner = DefaultUnsupportedAppScanner()
        let unusedScanner = DefaultUnusedAppScanner()
        let leftoverScanner = DefaultAppLeftoverScanner()
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "ApplicationsViewModel.live")
        return ApplicationsViewModel(
            discoverApps: {
                try await discovery.installedApps(includingSystemApps: false)
            },
            checkUpdates: { apps in
                await probe.availableUpdates(for: apps)
            },
            scanInstallationFiles: {
                await installerScanner.scan()
            },
            scanUnsupportedApps: { apps in
                await unsupportedScanner.scan(apps: apps)
            },
            scanUnusedApps: { apps in
                await unusedScanner.scan(apps: apps)
            },
            scanLeftovers: { installedBundleIDs in
                await leftoverScanner.scan(installedBundleIDs: installedBundleIDs)
            },
            recycleFiles: { urls in
                await Self.recycle(urls, log: log)
            }
        )
    }

    /// Default deleter: move each installer to the user's Trash via
    /// `NSWorkspace.recycle` (restorable) and return the set of URLs that
    /// actually moved. `NSWorkspace.recycle` Trashes what it can and reports an
    /// error only when the whole batch fails, so the success set comes from the
    /// returned original→Trash URL map. Marked `nonisolated` so the batch runs
    /// off the main actor.
    nonisolated private static func recycle(_ urls: [URL], log: Logger) async -> Set<URL> {
        guard !urls.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { newURLs, error in
                if let error {
                    log.error("Installation-file recycle reported an error: \(String(describing: error), privacy: .public)")
                }
                continuation.resume(returning: Set(newURLs.keys.map { $0 }))
            }
        }
    }

}

// MARK: - ScanCoordinating

extension ApplicationsViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.results`/`.failed` both want the section's own detail UI,
    /// whose internal switch renders the specifics (grid vs. failed state).
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning:
            return .working
        case .results, .failed:
            return .results
        }
    }

    func beginScan() {
        runScanActivity { await self.scan() }
    }
}
