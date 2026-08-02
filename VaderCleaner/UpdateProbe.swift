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

/// Why an app was never queried for updates. The split matters: an app
/// carrying Keystone or Squirrel keeps itself current and needs no
/// attention, while an app with no updater at all is the one the user
/// would actually want to know about. Reporting both as one number
/// produces an alarming total that is mostly noise.
enum UncheckedReason: Hashable, Sendable {
    case selfUpdating(SelfUpdater)
    /// Installed by the named Homebrew cask. Handing this app a direct
    /// download would overwrite a Caskroom-tracked install, so it is left
    /// to the Homebrew surface, which upgrades it in place.
    case homebrew(token: String)
    case unmonitored
}

/// Per-app result after version comparison. `.noUpdate` means the
/// feed was reached but there is nothing newer to offer (including a
/// swallowed non-network failure — the server answered, so the
/// network is fine). `.unreachable` means the feed could not be
/// reached at all. `.skipped` means no request was attempted (no
/// feed configured), and carries why. `AppUpdaterViewModel` uses the
/// reachable/unreachable split to tell "up to date" from "offline",
/// and keeps `.skipped` out of that split entirely.
enum UpdateProbeOutcome: Sendable {
    case update(UpdateInfo)
    case noUpdate
    case unreachable
    case skipped(UncheckedReason)
}

/// An outcome paired with the app that produced it. The fan-out returns
/// results in *completion* order, so without the pairing there is no way
/// to say which apps went unchecked — which is the whole content of the
/// coverage report.
struct UpdateProbeResult: Sendable {
    let app: AppInfo
    let outcome: UpdateProbeOutcome
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
    /// Explains an app that no channel could query. Runs only for skipped
    /// apps, so the bundle reads it performs stay off the checked path.
    typealias ClassifyUnchecked = @Sendable (_ app: AppInfo) -> UncheckedReason
    /// The Homebrew cask token that installed this app, or nil when
    /// Homebrew doesn't own it. Consulted *before* any channel dispatch.
    typealias ResolveHomebrewToken = @Sendable (_ app: AppInfo) -> String?

    /// Maximum number of update checks (HTTPS requests) in flight at once.
    /// Sized to keep the scan responsive without stampeding the iTunes
    /// Search API / Sparkle hosts on machines with many installed apps.
    static let maxConcurrentChecks = 6

    private let checkAppStore: CheckAppStore
    private let checkSparkle: CheckSparkle
    private let classifyUnchecked: ClassifyUnchecked
    private let resolveHomebrewToken: ResolveHomebrewToken

    /// - Parameter classifyUnchecked: defaults to the real bundle-reading
    ///   detector. It is the safe default in both directions — production
    ///   gets true classification without every call site wiring it, and
    ///   tests pointing at paths that don't exist get `.unmonitored`.
    /// - Parameter resolveHomebrewToken: defaults to claiming nothing.
    ///   The ownership map is built asynchronously (it shells out to
    ///   `brew`), so the caller loads it first and captures it here.
    init(
        checkAppStore: @escaping CheckAppStore,
        checkSparkle: @escaping CheckSparkle,
        classifyUnchecked: @escaping ClassifyUnchecked = UpdateProbe.liveClassifyUnchecked(),
        resolveHomebrewToken: @escaping ResolveHomebrewToken = { _ in nil }
    ) {
        self.checkAppStore = checkAppStore
        self.checkSparkle = checkSparkle
        self.classifyUnchecked = classifyUnchecked
        self.resolveHomebrewToken = resolveHomebrewToken
    }

    /// Probes every app and returns one outcome per app, in completion
    /// order. Bounded concurrency: a machine with hundreds of installed
    /// apps would otherwise fire hundreds of simultaneous HTTPS requests
    /// at the iTunes Search API and assorted Sparkle feeds, inviting rate
    /// limiting. A sliding window keeps the checks parallel but caps
    /// in-flight work at `maxConcurrentChecks`.
    ///
    /// `onProgress` reports determinate progress: it fires once up front with
    /// `(0, apps.count)` so a caller can show the total, then again after each
    /// app's check completes with the running `(checked, total)`. The default
    /// no-op keeps the callers that don't surface progress unchanged.
    func outcomes(
        for apps: [AppInfo],
        onProgress: @Sendable (_ checked: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> [UpdateProbeResult] {
        let appStoreCheck = checkAppStore
        let sparkleCheck = checkSparkle
        let classify = classifyUnchecked
        let resolveToken = resolveHomebrewToken
        let total = apps.count
        onProgress(0, total)
        return await withTaskGroup(of: UpdateProbeResult.self) { group -> [UpdateProbeResult] in
            var nextIndex = 0
            while nextIndex < apps.count, nextIndex < Self.maxConcurrentChecks {
                let app = apps[nextIndex]
                group.addTask {
                    await Self.checkUpdate(
                        app: app,
                        appStoreCheck: appStoreCheck,
                        sparkleCheck: sparkleCheck,
                        classify: classify,
                        resolveToken: resolveToken
                    )
                }
                nextIndex += 1
            }
            var results: [UpdateProbeResult] = []
            while let result = await group.next() {
                results.append(result)
                onProgress(results.count, total)
                if nextIndex < apps.count {
                    let app = apps[nextIndex]
                    group.addTask {
                        await Self.checkUpdate(
                            app: app,
                            appStoreCheck: appStoreCheck,
                            sparkleCheck: sparkleCheck,
                            classify: classify,
                            resolveToken: resolveToken
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
    /// just the available updates. `onProgress` forwards the per-app
    /// completion ticks from `outcomes(for:onProgress:)`.
    func availableUpdates(
        for apps: [AppInfo],
        onProgress: @Sendable (_ checked: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> [UpdateInfo] {
        Self.updates(in: await outcomes(for: apps, onProgress: onProgress))
    }

    /// Extracts the `.update` payloads, sorted case-insensitively by app
    /// name so the list order is deterministic between successive checks.
    static func updates(in results: [UpdateProbeResult]) -> [UpdateInfo] {
        let updates = results.compactMap { result -> UpdateInfo? in
            guard case .update(let info) = result.outcome else { return nil }
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
        sparkleCheck: CheckSparkle,
        classify: ClassifyUnchecked,
        resolveToken: ResolveHomebrewToken
    ) async -> UpdateProbeResult {
        // Homebrew ownership is decided before any dispatch. A cask-owned
        // app must never produce an update row: its download would
        // overwrite a Caskroom-tracked install. Checking it first also
        // spares the network request entirely.
        if let token = resolveToken(app) {
            return UpdateProbeResult(app: app, outcome: .skipped(.homebrew(token: token)))
        }
        // The channel functions return nil for "no request was made"; the
        // reason is filled in here. Classification reads the bundle off
        // disk, so it runs only for skipped apps, never on the checked path.
        let outcome = app.isAppStore
            ? await checkAppStoreUpdate(app: app, check: appStoreCheck)
            : await checkSparkleUpdate(app: app, check: sparkleCheck)
        return UpdateProbeResult(
            app: app,
            outcome: outcome ?? .skipped(classify(app))
        )
    }

    /// Runs the App Store lookup and folds the result into an
    /// `UpdateInfo` if (and only if) the remote version is newer than
    /// the installed one. An unreachable feed reports `.unreachable` so
    /// an aggregator can distinguish offline from up-to-date; one slow
    /// checker still must not blank the whole update list.
    private static func checkAppStoreUpdate(
        app: AppInfo,
        check: CheckAppStore
    ) async -> UpdateProbeOutcome? {
        switch await check(app.bundleID) {
        case .unreachable:
            return .unreachable
        case .noResult:
            return .noUpdate
        case .skipped:
            // No request was made — the caller classifies why.
            return nil
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
                updateURL: lookup.appStoreURL,
                releaseNotes: lookup.releaseNotes
            ))
        }
    }

    private static func checkSparkleUpdate(
        app: AppInfo,
        check: CheckSparkle
    ) async -> UpdateProbeOutcome? {
        switch await check(app) {
        case .unreachable:
            return .unreachable
        case .noResult:
            return .noUpdate
        case .skipped:
            // No feed configured — the caller classifies why.
            return nil
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
                updateURL: item.downloadURL,
                edSignature: item.edSignature,
                releaseNotes: item.releaseNotes
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
            checkSparkle: liveSparkleCheck(),
            classifyUnchecked: liveClassifyUnchecked()
        )
    }

    /// Live skip classifier. An app the probe could not query either ships
    /// its own updater (Keystone, Squirrel) or has none at all, and only
    /// the second is worth the user's attention.
    static func liveClassifyUnchecked(
        detector: SelfUpdaterDetector = SelfUpdaterDetector()
    ) -> ClassifyUnchecked {
        { app in
            guard let updater = detector.selfUpdater(for: app) else { return .unmonitored }
            return .selfUpdating(updater)
        }
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
