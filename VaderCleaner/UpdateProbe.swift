// UpdateProbe.swift
// Shared update-check pipeline — routes each installed app to its App Store or Sparkle channel, compares versions, and fans the per-app probes out with bounded concurrency. Used by the App Updater, the Applications dashboard, and Smart Scan so all three surfaces produce identical update lists.

import Foundation

/// Outcome of a single update-feed lookup. `.unreachable` is the
/// signal Prompt 20's swallow contract was missing: it lets the
/// view-model tell "this feed was down" apart from "this app has no
/// update", so a genuinely offline check can surface the network copy
/// while a single dead feed still never blanks the whole list. Generic
/// over the payload so the App Store and Sparkle channels share one
/// shape instead of near-identical enums.
///
/// `.noResult` means a network round-trip completed but carried nothing
/// actionable (no MAS entry, nothing newer, or a swallowed non-network
/// failure) — proof the network is up. `.skipped` means no request was
/// ever made (e.g. the app carries no `SUFeedURL`), so it must stay
/// neutral in the offline decision: counting a skipped app as "reached"
/// would mask a genuinely offline machine the moment one non-updatable
/// app is installed — which is essentially always.
enum CheckResult<Payload: Sendable>: Sendable {
    case found(Payload)
    case noResult
    case unreachable
    case skipped
}

/// Per-app result after version comparison. `.noUpdate` means the
/// feed was reached but there is nothing newer to offer (including a
/// swallowed non-network failure — the server answered, so the
/// network is fine). `.unreachable` means the feed could not be
/// reached at all. `.skipped` means no request was attempted (no
/// feed configured). `AppUpdaterViewModel` uses the
/// reachable/unreachable split to tell "up to date" from "offline",
/// and keeps `.skipped` out of that split entirely.
enum UpdateProbeOutcome: Sendable {
    case update(UpdateInfo)
    case noUpdate
    case unreachable
    case skipped
}

/// Probes installed apps for available updates. Each app is dispatched
/// to exactly one channel — the App Store lookup when the bundle carries
/// a MAS receipt, the Sparkle appcast otherwise — and a remote version is
/// folded into an `UpdateInfo` only when it is strictly newer than the
/// installed one.
///
/// Checkers are injected as closures so unit tests can drive every
/// outcome without touching the network. Production wiring lives in
/// `UpdateProbe.live()`.
struct UpdateProbe: Sendable {

    typealias CheckAppStore = @Sendable (_ bundleID: String) async -> CheckResult<AppStoreLookup>
    typealias CheckSparkle  = @Sendable (_ app: AppInfo) async -> CheckResult<SparkleAppcastItem>

    /// Maximum number of update checks (HTTPS requests) in flight at once.
    /// Sized to keep the scan responsive without stampeding the iTunes
    /// Search API / Sparkle hosts on machines with many installed apps.
    static let maxConcurrentChecks = 6

    private let checkAppStore: CheckAppStore
    private let checkSparkle: CheckSparkle

    init(
        checkAppStore: @escaping CheckAppStore,
        checkSparkle: @escaping CheckSparkle
    ) {
        self.checkAppStore = checkAppStore
        self.checkSparkle = checkSparkle
    }

    /// Probes every app and returns one outcome per app, in completion
    /// order. Bounded concurrency: a machine with hundreds of installed
    /// apps would otherwise fire hundreds of simultaneous HTTPS requests
    /// at the iTunes Search API and assorted Sparkle feeds, inviting rate
    /// limiting. A sliding window keeps the checks parallel but caps
    /// in-flight work at `maxConcurrentChecks`.
    func outcomes(for apps: [AppInfo]) async -> [UpdateProbeOutcome] {
        let appStoreCheck = checkAppStore
        let sparkleCheck = checkSparkle
        return await withTaskGroup(of: UpdateProbeOutcome.self) { group -> [UpdateProbeOutcome] in
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
            var results: [UpdateProbeOutcome] = []
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
    }

    /// Convenience for surfaces that only need the update list (the
    /// Applications dashboard, Smart Scan): probes every app and returns
    /// just the available updates.
    func availableUpdates(for apps: [AppInfo]) async -> [UpdateInfo] {
        Self.updates(in: await outcomes(for: apps))
    }

    /// Extracts the `.update` payloads, sorted case-insensitively by app
    /// name so the list order is deterministic between successive checks.
    static func updates(in outcomes: [UpdateProbeOutcome]) -> [UpdateInfo] {
        let updates = outcomes.compactMap { outcome -> UpdateInfo? in
            guard case .update(let info) = outcome else { return nil }
            return info
        }
        return updates.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    // MARK: - Per-app channel dispatch

    /// Dispatches a single app to the correct update channel. The two
    /// channels are independent — a Sparkle-bundled app uploaded later to
    /// the Mac App Store would appear in `isAppStore`, so the dispatch is
    /// exclusive.
    private static func checkUpdate(
        app: AppInfo,
        appStoreCheck: CheckAppStore,
        sparkleCheck: CheckSparkle
    ) async -> UpdateProbeOutcome {
        if app.isAppStore {
            return await checkAppStoreUpdate(app: app, check: appStoreCheck)
        } else {
            return await checkSparkleUpdate(app: app, check: sparkleCheck)
        }
    }

    /// Runs the App Store lookup and folds the result into an
    /// `UpdateInfo` if (and only if) the remote version is newer than
    /// the installed one. An unreachable feed reports `.unreachable` so
    /// an aggregator can distinguish offline from up-to-date; one slow
    /// checker still must not blank the whole update list.
    private static func checkAppStoreUpdate(
        app: AppInfo,
        check: CheckAppStore
    ) async -> UpdateProbeOutcome {
        switch await check(app.bundleID) {
        case .unreachable:
            return .unreachable
        case .noResult:
            return .noUpdate
        case .skipped:
            return .skipped
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
    ) async -> UpdateProbeOutcome {
        switch await check(app) {
        case .unreachable:
            return .unreachable
        case .noResult:
            return .noUpdate
        case .skipped:
            return .skipped
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

extension UpdateProbe {

    /// Probe wired to the real `DefaultAppStoreUpdateChecker` and
    /// `DefaultSparkleUpdateChecker`.
    static func live() -> UpdateProbe {
        UpdateProbe(
            checkAppStore: liveAppStoreCheck(),
            checkSparkle: liveSparkleCheck()
        )
    }

    /// Live App Store checker. Re-surfaces only loss of connectivity.
    /// Every other failure (a decode error, a malformed response) stays
    /// swallowed as `.noResult` so one bad app can never blank the list —
    /// Prompt 20's partial-degradation contract is preserved, not
    /// reversed.
    static func liveAppStoreCheck(
        appStore: DefaultAppStoreUpdateChecker = DefaultAppStoreUpdateChecker()
    ) -> CheckAppStore {
        { bundleID in
            do {
                if let lookup = try await appStore.latestVersion(forBundleID: bundleID) {
                    return .found(lookup)
                }
                return .noResult
            } catch {
                return AppUpdaterError.isNetworkError(error) ? .unreachable : .noResult
            }
        }
    }

    /// Live Sparkle checker. Apps without an `SUFeedURL` are `.skipped`
    /// (no request is made); failures follow the same network/non-network
    /// split as the App Store checker.
    static func liveSparkleCheck(
        sparkle: DefaultSparkleUpdateChecker = DefaultSparkleUpdateChecker()
    ) -> CheckSparkle {
        { app in
            guard let feedURL = sparkle.feedURL(for: app) else { return .skipped }
            do {
                if let item = try await sparkle.fetchAppcast(feedURL: feedURL) {
                    return .found(item)
                }
                return .noResult
            } catch {
                return AppUpdaterError.isNetworkError(error) ? .unreachable : .noResult
            }
        }
    }
}
