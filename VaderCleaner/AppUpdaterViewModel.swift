// AppUpdaterViewModel.swift
// State machine and orchestration behind the App Updater feature view — fans installed apps out to App Store and Sparkle checkers concurrently, merges results, suppresses up-to-date apps, and routes user-initiated updates to NSWorkspace.

import AppKit
import Foundation
import os.log

/// Outcome of a single update-feed lookup. `.unreachable` is the
/// signal Prompt 20's swallow contract was missing: it lets the
/// view-model tell "this feed was down" apart from "this app has no
/// update", so a genuinely offline check can surface the network copy
/// while a single dead feed still never blanks the whole list. Generic
/// over the payload so the App Store and Sparkle channels share one
/// three-way shape (a result, a reached feed with nothing to offer, or
/// an unreachable feed) instead of two near-identical enums.
enum CheckResult<Payload: Sendable>: Sendable {
    case found(Payload)
    case noResult
    case unreachable
}

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
    typealias CheckAppStore  = @Sendable (_ bundleID: String) async -> CheckResult<AppStoreLookup>
    typealias CheckSparkle   = @Sendable (_ app: AppInfo) async -> CheckResult<SparkleAppcastItem>
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
            let outcomes = await withTaskGroup(of: AppCheckOutcome.self) { group -> [AppCheckOutcome] in
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
                var results: [AppCheckOutcome] = []
                while let outcome = await group.next() {
                    results.append(outcome)
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

            var updates: [UpdateInfo] = []
            var anyReachable = false
            var anyUnreachable = false
            for outcome in outcomes {
                switch outcome {
                case .update(let info):
                    updates.append(info)
                    anyReachable = true
                case .noUpdate:
                    anyReachable = true
                case .unreachable:
                    anyUnreachable = true
                }
            }

            // Sort case-insensitively by app name so the list order is
            // deterministic between successive checks.
            self.availableUpdates = updates.sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }

            // Offline only when *every* feed we contacted was
            // unreachable and not one came back with an answer. If even
            // one feed responded — or we found updates — the network is
            // up and Prompt 20's partial degradation stands: show what
            // we have rather than a network error.
            if updates.isEmpty, !anyReachable, anyUnreachable {
                self.phase = .failed(
                    message: AppUpdaterError.userFacingMessage(
                        for: AppUpdaterError.networkUnavailable
                    )
                )
            } else {
                self.phase = .ready
            }
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("App Updater discovery failed: \(String(describing: error), privacy: .private)")
            guard self.checkGeneration == generation else { return }
            self.availableUpdates = []
            self.phase = .failed(message: AppUpdaterError.userFacingMessage(for: error))
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

    /// Per-app result after version comparison. `.noUpdate` means the
    /// feed was reached but there is nothing newer to offer (including a
    /// swallowed non-network failure — the server answered, so the
    /// network is fine). `.unreachable` means the feed could not be
    /// reached at all. The aggregator in `checkForUpdates()` uses the
    /// reachable/unreachable split to tell "up to date" from "offline".
    private enum AppCheckOutcome {
        case update(UpdateInfo)
        case noUpdate
        case unreachable
    }

    /// Dispatches a single app to the correct update channel. Factored
    /// out of `checkForUpdates()` so the bounded-concurrency window can
    /// schedule the same task body in two places without duplication.
    private static func checkUpdate(
        app: AppInfo,
        appStoreCheck: CheckAppStore,
        sparkleCheck: CheckSparkle
    ) async -> AppCheckOutcome {
        if app.isAppStore {
            return await checkAppStoreUpdate(app: app, check: appStoreCheck)
        } else {
            return await checkSparkleUpdate(app: app, check: sparkleCheck)
        }
    }

    /// Runs the App Store lookup and folds the result into an
    /// `UpdateInfo` if (and only if) the remote version is newer than
    /// the installed one. An unreachable feed reports `.unreachable` so
    /// the aggregator can distinguish offline from up-to-date; one slow
    /// checker still must not blank the whole update list.
    private static func checkAppStoreUpdate(
        app: AppInfo,
        check: CheckAppStore
    ) async -> AppCheckOutcome {
        switch await check(app.bundleID) {
        case .unreachable:
            return .unreachable
        case .noResult:
            return .noUpdate
        case .found(let lookup):
            let installed = app.version ?? "0"
            guard VersionComparator.isNewer(version: lookup.version, than: installed) else {
                return .noUpdate
            }
            return .update(UpdateInfo(
                appName: app.name,
                bundleID: app.bundleID,
                bundleURL: app.bundleURL,
                installedVersion: installed,
                latestVersion: lookup.version,
                source: .appStore,
                updateURL: lookup.appStoreURL
            ))
        }
    }

    private static func checkSparkleUpdate(
        app: AppInfo,
        check: CheckSparkle
    ) async -> AppCheckOutcome {
        switch await check(app) {
        case .unreachable:
            return .unreachable
        case .noResult:
            return .noUpdate
        case .found(let item):
            let installed = app.version ?? "0"
            guard VersionComparator.isNewer(version: item.shortVersion, than: installed) else {
                return .noUpdate
            }
            return .update(UpdateInfo(
                appName: app.name,
                bundleID: app.bundleID,
                bundleURL: app.bundleURL,
                installedVersion: installed,
                latestVersion: item.shortVersion,
                source: .sparkle,
                updateURL: item.downloadURL
            ))
        }
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
                    if let lookup = try await appStore.latestVersion(forBundleID: bundleID) {
                        return .found(lookup)
                    }
                    return .noResult
                } catch {
                    // Re-surface only loss of connectivity. Every other
                    // failure (a decode error, a malformed response)
                    // stays swallowed as `.noResult` so one bad app can
                    // never blank the list — Prompt 20's partial-
                    // degradation contract is preserved, not reversed.
                    return AppUpdaterError.isNetworkError(error) ? .unreachable : .noResult
                }
            },
            checkSparkle: { app in
                guard let feedURL = sparkle.feedURL(for: app) else { return .noResult }
                do {
                    if let item = try await sparkle.fetchAppcast(feedURL: feedURL) {
                        return .found(item)
                    }
                    return .noResult
                } catch {
                    return AppUpdaterError.isNetworkError(error) ? .unreachable : .noResult
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
