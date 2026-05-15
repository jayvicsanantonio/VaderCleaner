// AppUpdaterViewModel.swift
// State machine and orchestration behind the App Updater feature view — fans installed apps out to App Store and Sparkle checkers concurrently, merges results, suppresses up-to-date apps, and routes user-initiated updates to NSWorkspace.

import AppKit
import Foundation
import os.log

/// Drives the App Updater feature view (check → ready → update).
///
/// All collaborators are injected as closures so unit tests can drive
/// every transition without touching real apps or the network. Production
/// wiring lives in `AppUpdaterViewModel.live()`.
@MainActor
final class AppUpdaterViewModel: ObservableObject {

    /// Discrete phases the view binds to.
    enum Phase: Equatable {
        case idle
        case checking
        case ready
        case failed(message: String)
    }

    typealias Discover       = @Sendable (_ includingSystemApps: Bool) async throws -> [AppInfo]
    typealias CheckAppStore  = @Sendable (_ bundleID: String) async -> AppStoreLookup?
    typealias CheckSparkle   = @Sendable (_ app: AppInfo) async -> SparkleAppcastItem?
    typealias Opener         = @Sendable (_ url: URL) async -> Void

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var availableUpdates: [UpdateInfo] = []

    private let discover: Discover
    private let checkAppStore: CheckAppStore
    private let checkSparkle: CheckSparkle
    private let opener: Opener
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "AppUpdaterViewModel")

    /// Monotonic counter — a second `checkForUpdates()` invalidates the
    /// older results so a slow first pass can't overwrite a fresh second
    /// pass with stale data. Same pattern as `AppUninstallerViewModel`.
    private var checkGeneration: Int = 0

    init(
        discover: @escaping Discover,
        checkAppStore: @escaping CheckAppStore,
        checkSparkle: @escaping CheckSparkle,
        opener: @escaping Opener
    ) {
        self.discover = discover
        self.checkAppStore = checkAppStore
        self.checkSparkle = checkSparkle
        self.opener = opener
    }

    // MARK: - Actions

    /// Discovers installed apps and dispatches each to either the App
    /// Store or the Sparkle checker. The two channels are independent —
    /// a Sparkle-bundled app uploaded later to the Mac App Store would
    /// appear in `isAppStore`, so the dispatch is exclusive.
    func checkForUpdates() async {
        let generation = beginCheck()
        phase = .checking
        do {
            let apps = try await discover(false)
            // Bind to locals so the captured values in the TaskGroup
            // don't accidentally reach back into the actor — closures
            // are already `@Sendable`, but keeping the capture explicit
            // makes the data flow obvious.
            let appStoreCheck = self.checkAppStore
            let sparkleCheck = self.checkSparkle
            let updates = await withTaskGroup(of: UpdateInfo?.self) { group -> [UpdateInfo] in
                // Bounded concurrency: a machine with hundreds of installed
                // apps would otherwise fire hundreds of simultaneous HTTPS
                // requests at the iTunes Search API and assorted Sparkle
                // feeds, inviting rate limiting. A sliding window keeps the
                // checks parallel but caps in-flight work.
                var nextIndex = 0
                while nextIndex < apps.count, nextIndex < Self.maxConcurrentChecks {
                    let app = apps[nextIndex]
                    group.addTask {
                        await Self.checkUpdate(
                            app: app,
                            appStoreCheck: appStoreCheck,
                            sparkleCheck: sparkleCheck
                        )
                    }
                    nextIndex += 1
                }
                var results: [UpdateInfo] = []
                while let item = await group.next() {
                    if let item { results.append(item) }
                    if nextIndex < apps.count {
                        let app = apps[nextIndex]
                        group.addTask {
                            await Self.checkUpdate(
                                app: app,
                                appStoreCheck: appStoreCheck,
                                sparkleCheck: sparkleCheck
                            )
                        }
                        nextIndex += 1
                    }
                }
                return results
            }
            guard self.checkGeneration == generation else { return }
            // Sort case-insensitively by app name so the list order is
            // deterministic between successive checks.
            self.availableUpdates = updates.sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
            self.phase = .ready
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("App Updater discovery failed: \(String(describing: error), privacy: .private)")
            guard self.checkGeneration == generation else { return }
            self.availableUpdates = []
            self.phase = .failed(message: error.localizedDescription)
        }
    }

    /// Opens the per-app update URL — Mac App Store URL for `appStore`
    /// entries, the appcast enclosure URL for Sparkle entries. The
    /// production opener delegates to `NSWorkspace.open`.
    func update(_ info: UpdateInfo) async {
        await opener(info.updateURL)
    }

    /// Opens every available update's URL in sequence. The system
    /// handles deduplication if multiple URLs point at the same App
    /// Store entry.
    func updateAll() async {
        for info in availableUpdates {
            await opener(info.updateURL)
        }
    }

    // MARK: - Private

    /// Maximum number of update checks (HTTPS requests) in flight at once.
    /// Sized to keep the scan responsive without stampeding the iTunes
    /// Search API / Sparkle hosts on machines with many installed apps.
    private static let maxConcurrentChecks = 6

    private func beginCheck() -> Int {
        checkGeneration += 1
        return checkGeneration
    }

    /// Dispatches a single app to the correct update channel. Factored
    /// out of `checkForUpdates()` so the bounded-concurrency window can
    /// schedule the same task body in two places without duplication.
    private static func checkUpdate(
        app: AppInfo,
        appStoreCheck: CheckAppStore,
        sparkleCheck: CheckSparkle
    ) async -> UpdateInfo? {
        if app.isAppStore {
            return await checkAppStoreUpdate(app: app, check: appStoreCheck)
        } else {
            return await checkSparkleUpdate(app: app, check: sparkleCheck)
        }
    }

    /// Runs the App Store lookup and folds the result into an
    /// `UpdateInfo` if (and only if) the remote version is newer than
    /// the installed one. A network failure inside the lookup returns
    /// `nil` — one slow checker must not blank the whole update list.
    private static func checkAppStoreUpdate(
        app: AppInfo,
        check: CheckAppStore
    ) async -> UpdateInfo? {
        guard let lookup = await check(app.bundleID) else { return nil }
        let installed = app.version ?? "0"
        guard VersionComparator.isNewer(version: lookup.version, than: installed) else {
            return nil
        }
        return UpdateInfo(
            appName: app.name,
            bundleID: app.bundleID,
            bundleURL: app.bundleURL,
            installedVersion: installed,
            latestVersion: lookup.version,
            source: .appStore,
            updateURL: lookup.appStoreURL
        )
    }

    private static func checkSparkleUpdate(
        app: AppInfo,
        check: CheckSparkle
    ) async -> UpdateInfo? {
        guard let item = await check(app) else { return nil }
        let installed = app.version ?? "0"
        guard VersionComparator.isNewer(version: item.shortVersion, than: installed) else {
            return nil
        }
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

// MARK: - Production wiring

extension AppUpdaterViewModel {

    /// Build a view-model wired to the real `DefaultAppDiscovery`,
    /// `DefaultAppStoreUpdateChecker`, `DefaultSparkleUpdateChecker`, and
    /// `NSWorkspace.open`.
    @MainActor
    static func live() -> AppUpdaterViewModel {
        let discovery = DefaultAppDiscovery()
        let appStore = DefaultAppStoreUpdateChecker()
        let sparkle = DefaultSparkleUpdateChecker()
        return AppUpdaterViewModel(
            discover: { includingSystemApps in
                try await discovery.installedApps(includingSystemApps: includingSystemApps)
            },
            checkAppStore: { bundleID in
                do {
                    return try await appStore.latestVersion(forBundleID: bundleID)
                } catch {
                    return nil
                }
            },
            checkSparkle: { app in
                guard let feedURL = sparkle.feedURL(for: app) else { return nil }
                do {
                    return try await sparkle.fetchAppcast(feedURL: feedURL)
                } catch {
                    return nil
                }
            },
            opener: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            }
        )
    }
}
