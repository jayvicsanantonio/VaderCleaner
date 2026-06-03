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
    /// Moves the given files to the Trash and returns the set of URLs actually
    /// recycled. Partial success is the norm (a locked file must not abort the
    /// batch), so the return is the success set — mirroring
    /// `LargeOldFilesViewModel.Deleter`.
    typealias RecycleFiles = @Sendable ([URL]) async -> Set<URL>

    private(set) var phase: Phase = .idle

    /// Per-file gate for the Installation Files review screen, keyed by URL.
    /// Seeded *empty* — removal is destructive, so the user opts each installer
    /// in explicitly, matching `LargeOldFilesViewModel`.
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

    @ObservationIgnored private let discoverApps: DiscoverApps
    @ObservationIgnored private let checkUpdates: CheckUpdates
    @ObservationIgnored private let scanInstallationFiles: ScanInstallationFiles
    @ObservationIgnored private let scanUnsupportedApps: ScanUnsupportedApps
    @ObservationIgnored private let scanUnusedApps: ScanUnusedApps
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
        recycleFiles: @escaping RecycleFiles
    ) {
        self.discoverApps = discoverApps
        self.checkUpdates = checkUpdates
        self.scanInstallationFiles = scanInstallationFiles
        self.scanUnsupportedApps = scanUnsupportedApps
        self.scanUnusedApps = scanUnusedApps
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

        do {
            // The installer scan is independent of app discovery, so run it
            // concurrently with the discover → update-check chain.
            async let installersAsync = scanInstallationFiles()
            let apps = try await discoverApps()
            // The update check and the per-app scans all need the discovered
            // apps, so fan them out concurrently once they're known.
            async let updatesAsync = checkUpdates(apps)
            async let unsupportedAsync = scanUnsupportedApps(apps)
            async let unusedAsync = scanUnusedApps(apps)
            let installers = await installersAsync
            let updates = await updatesAsync
            let unsupported = await unsupportedAsync
            let unused = await unusedAsync
            guard scanGeneration == generation else { return }
            phase = .results(ApplicationsScanResult(
                installedApps: apps,
                availableUpdates: updates,
                installationFiles: installers,
                unsupportedApps: unsupported,
                unusedApps: unused
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
}

// MARK: - Production wiring

extension ApplicationsViewModel {

    /// Builds a view-model wired to the real `DefaultAppDiscovery` and the App
    /// Store / Sparkle update checkers — the same collaborators
    /// `AppUpdaterViewModel.live` uses, so the dashboard's update count matches
    /// the updater list it opens.
    @MainActor
    static func live() -> ApplicationsViewModel {
        let discovery = DefaultAppDiscovery()
        let appStore = DefaultAppStoreUpdateChecker()
        let sparkle = DefaultSparkleUpdateChecker()
        let installerScanner = DefaultInstallationFileScanner()
        let unsupportedScanner = DefaultUnsupportedAppScanner()
        let unusedScanner = DefaultUnusedAppScanner()
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "ApplicationsViewModel.live")
        return ApplicationsViewModel(
            discoverApps: {
                try await discovery.installedApps(includingSystemApps: false)
            },
            checkUpdates: { apps in
                await Self.fetchUpdates(for: apps, appStore: appStore, sparkle: sparkle, log: log)
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

    /// Bounded-concurrency (≤6 in-flight HTTPS requests) discover-and-probe
    /// loop over already-discovered apps. Mirrors
    /// `AppUpdaterViewModel.checkForUpdates`'s sliding window so a heavily-
    /// installed machine never stampedes the iTunes Search API or assorted
    /// Sparkle hosts. Marked `nonisolated` so the HTTP fan-out runs off the
    /// main actor instead of serializing on the UI thread.
    nonisolated private static func fetchUpdates(
        for apps: [AppInfo],
        appStore: DefaultAppStoreUpdateChecker,
        sparkle: DefaultSparkleUpdateChecker,
        log: Logger
    ) async -> [UpdateInfo] {
        let updates = await withTaskGroup(of: UpdateInfo?.self) { group -> [UpdateInfo] in
            var nextIndex = 0
            let maxInFlight = 6
            while nextIndex < apps.count, nextIndex < maxInFlight {
                let app = apps[nextIndex]
                group.addTask {
                    await Self.checkUpdate(for: app, appStore: appStore, sparkle: sparkle)
                }
                nextIndex += 1
            }
            var results: [UpdateInfo] = []
            while let result = await group.next() {
                if let info = result { results.append(info) }
                if nextIndex < apps.count {
                    let app = apps[nextIndex]
                    group.addTask {
                        await Self.checkUpdate(for: app, appStore: appStore, sparkle: sparkle)
                    }
                    nextIndex += 1
                }
            }
            return results
        }
        return updates.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    /// Routes a single installed app to its update channel and returns an
    /// `UpdateInfo` only when the remote version is strictly newer. Every
    /// failure — network, decode, missing feed — is swallowed to `nil` so one
    /// bad app can never blank the whole list.
    nonisolated private static func checkUpdate(
        for app: AppInfo,
        appStore: DefaultAppStoreUpdateChecker,
        sparkle: DefaultSparkleUpdateChecker
    ) async -> UpdateInfo? {
        if app.isAppStore {
            guard let lookup = (try? await appStore.latestVersion(forBundleID: app.bundleID)) ?? nil else {
                return nil
            }
            let installed = app.version ?? "0"
            guard VersionComparator.isNewer(version: lookup.version, than: installed) else { return nil }
            return UpdateInfo(
                appName: app.name,
                bundleID: app.bundleID,
                bundleURL: app.bundleURL,
                installedVersion: installed,
                latestVersion: lookup.version,
                source: .appStore,
                updateURL: lookup.appStoreURL
            )
        } else {
            guard let feedURL = sparkle.feedURL(for: app) else { return nil }
            guard let item = (try? await sparkle.fetchAppcast(feedURL: feedURL)) ?? nil else {
                return nil
            }
            let installed = app.version ?? "0"
            guard VersionComparator.isNewer(version: item.shortVersion, than: installed) else { return nil }
            return UpdateInfo(
                appName: app.name,
                bundleID: app.bundleID,
                bundleURL: app.bundleURL,
                installedVersion: installed,
                latestVersion: item.shortVersion,
                source: .sparkle,
                updateURL: item.downloadURL
            )
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
        Task { await scan() }
    }
}
