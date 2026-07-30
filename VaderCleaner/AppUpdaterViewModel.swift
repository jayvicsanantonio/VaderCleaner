// AppUpdaterViewModel.swift
// State machine and orchestration behind the App Updater feature view — fans installed apps out to App Store and Sparkle checkers concurrently, merges results, suppresses up-to-date apps, and routes user-initiated updates to NSWorkspace.

import AppKit
import Foundation
import Observation
import os.log

/// Drives the App Updater feature view (check → ready → update).
///
/// All collaborators are injected as closures so unit tests can drive
/// every transition without touching real apps or the network. Production
/// wiring lives in `AppUpdaterViewModel.live()`.
@MainActor
@Observable
final class AppUpdaterViewModel {

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
    /// Resolves which installed apps Homebrew owns. Async because it
    /// shells out to `brew`, so it is loaded once per check and the probe
    /// consults the resulting map synchronously.
    typealias LoadCaskOwnership = @Sendable () async -> CaskOwnershipMap

    private(set) var phase: Phase = .idle
    private(set) var availableUpdates: [UpdateInfo] = []
    /// How much of the installed-app population the last check reached.
    /// The list of updates alone reads as "everything else is current",
    /// which is false on any machine where most apps publish no feed.
    private(set) var coverage = UpdateCoverage()
    /// Updates withheld because the user declined this version. Surfaced
    /// so the choice is reversible — a skip the user cannot find again is
    /// indistinguishable from the update having vanished.
    private(set) var skippedUpdates: [UpdateInfo] = []

    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let checkAppStore: CheckAppStore
    @ObservationIgnored private let checkSparkle: CheckSparkle
    @ObservationIgnored private let classifyUnchecked: UpdateProbe.ClassifyUnchecked
    @ObservationIgnored private let loadCaskOwnership: LoadCaskOwnership
    /// Optional because "no suppression configured" is a real state — it
    /// is what the dashboard and Smart Scan paths use, and it keeps unit
    /// tests off `UserDefaults.standard` without every call site wiring a
    /// throwaway suite.
    @ObservationIgnored private let suppression: UpdateSuppressionStore?
    @ObservationIgnored private let opener: Opener
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "AppUpdaterViewModel")

    /// The Mac App Store's Updates page. Every App Store update in a
    /// batch routes here instead of to its own product page.
    static let appStoreUpdatesURL = URL(string: "macappstore://showUpdatesPage")!

    /// Monotonic counter — a second `checkForUpdates()` invalidates the
    /// older results so a slow first pass can't overwrite a fresh second
    /// pass with stale data. Same pattern as `AppUninstallerViewModel`.
    @ObservationIgnored private var checkGeneration: Int = 0

    init(
        discover: @escaping Discover,
        checkAppStore: @escaping CheckAppStore,
        checkSparkle: @escaping CheckSparkle,
        classifyUnchecked: @escaping UpdateProbe.ClassifyUnchecked
            = UpdateProbe.liveClassifyUnchecked(),
        loadCaskOwnership: @escaping LoadCaskOwnership = { CaskOwnershipMap() },
        suppression: UpdateSuppressionStore? = nil,
        opener: @escaping Opener
    ) {
        self.discover = discover
        self.checkAppStore = checkAppStore
        self.checkSparkle = checkSparkle
        self.classifyUnchecked = classifyUnchecked
        self.loadCaskOwnership = loadCaskOwnership
        self.suppression = suppression
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
            // Loaded once per check, then consulted synchronously per app.
            // An empty map claims nothing, so a machine without Homebrew
            // behaves exactly as it did before ownership existed.
            let ownership = await loadCaskOwnership()
            // The bounded-concurrency fan-out and per-app channel routing
            // live in `UpdateProbe`, shared with the Applications dashboard
            // and Smart Scan so all three surfaces produce identical update
            // lists.
            let probe = UpdateProbe(
                checkAppStore: checkAppStore,
                checkSparkle: checkSparkle,
                classifyUnchecked: classifyUnchecked,
                resolveHomebrewToken: { ownership.owner(of: $0)?.token }
            )
            let results = await probe.outcomes(for: apps)
            guard self.checkGeneration == generation else { return }

            var updates: [UpdateInfo] = []
            var anyReachable = false
            var anyUnreachable = false
            for result in results {
                switch result.outcome {
                case .update(let info):
                    updates.append(info)
                    anyReachable = true
                case .noUpdate:
                    anyReachable = true
                case .unreachable:
                    anyUnreachable = true
                case .skipped:
                    // No request was made — neither evidence the
                    // network is up nor that it is down. It still counts
                    // toward coverage, which is tallied separately.
                    break
                }
            }
            self.coverage = UpdateCoverage(results: results)

            updates = withholdDeclinedUpdates(from: updates, installedIn: apps)

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
            self.skippedUpdates = []
            // Stale counts beside an error would misreport what was
            // inspected — nothing was.
            self.coverage = UpdateCoverage()
            self.phase = .failed(message: AppUpdaterError.userFacingMessage(for: error))
        }
    }

    /// Opens the per-app update URL — Mac App Store URL for `appStore`
    /// entries, the appcast enclosure URL for Sparkle entries. The
    /// production opener delegates to `NSWorkspace.open`.
    func update(_ info: UpdateInfo) async {
        await opener(info.updateURL)
    }

    /// Declines `info.latestVersion` for its app. A later release still
    /// surfaces — this is "skip this version", not "mute this app".
    /// Inert when no suppression store is configured.
    func skip(_ info: UpdateInfo) {
        guard let suppression else { return }
        suppression.skip(info)
        availableUpdates.removeAll { $0.id == info.id }
        guard !skippedUpdates.contains(where: { $0.id == info.id }) else { return }
        skippedUpdates.append(info)
        skippedUpdates.sort {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    /// Undoes a skip, so the app's pending update is offered again on the
    /// next check.
    func clearSkip(forBundleID bundleID: String) {
        guard let suppression else { return }
        suppression.clearSkip(forBundleID: bundleID)
        // Move it straight back into the offered list rather than making
        // the user re-run a whole check to see the effect.
        let restored = skippedUpdates.filter { $0.bundleID == bundleID }
        skippedUpdates.removeAll { $0.bundleID == bundleID }
        availableUpdates.append(contentsOf: restored)
        availableUpdates.sort {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    /// Applies a batch of updates.
    ///
    /// App Store entries collapse to a **single** open of the Updates
    /// page: one product page per app buries the user in windows and
    /// still leaves them pressing Update once per app. Web downloads are
    /// deduplicated, since two apps from one suite can share an
    /// installer and starting the same download twice helps nobody.
    func update(_ infos: [UpdateInfo]) async {
        var opened = Set<URL>()
        if infos.contains(where: { $0.source == .appStore }) {
            opened.insert(Self.appStoreUpdatesURL)
            await opener(Self.appStoreUpdatesURL)
        }
        for info in infos where info.source != .appStore {
            guard opened.insert(info.updateURL).inserted else { continue }
            await opener(info.updateURL)
        }
    }

    /// Applies every available update.
    func updateAll() async {
        await update(availableUpdates)
    }

    // MARK: - Private

    /// Splits declined updates out of `updates` into `skippedUpdates`,
    /// and drops skip records the installed version has caught up to.
    ///
    /// Coverage is tallied before this runs and deliberately unaffected:
    /// a declined app was still contacted, so it stays counted as
    /// checked. Withholding it from the list must not make the coverage
    /// headline understate what the check actually did.
    private func withholdDeclinedUpdates(
        from updates: [UpdateInfo],
        installedIn apps: [AppInfo]
    ) -> [UpdateInfo] {
        guard let suppression else {
            skippedUpdates = []
            return updates
        }
        suppression.pruneSkips(
            installedVersionsByBundleID: Dictionary(
                apps.map { ($0.bundleID, $0.version ?? "0") },
                uniquingKeysWith: { first, _ in first }
            )
        )
        let declined = suppression.snapshot()
        skippedUpdates = updates
            .filter { declined.suppresses($0) }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        return updates.filter { !declined.suppresses($0) }
    }

    private func beginCheck() -> Int {
        checkGeneration += 1
        return checkGeneration
    }
}

// MARK: - Production wiring

extension AppUpdaterViewModel {

    /// Build a view-model wired to the real `DefaultAppDiscovery`,
    /// `UpdateProbe`'s live App Store / Sparkle checkers, and
    /// `NSWorkspace.open`.
    @MainActor
    static func live() -> AppUpdaterViewModel {
        let discovery = DefaultAppDiscovery()
        let ownershipLoader = CaskOwnershipLoader()
        return AppUpdaterViewModel(
            discover: { includingSystemApps in
                try await discovery.installedApps(includingSystemApps: includingSystemApps)
            },
            checkAppStore: UpdateProbe.liveAppStoreCheck(),
            checkSparkle: UpdateProbe.liveSparkleCheck(),
            loadCaskOwnership: { await ownershipLoader.load() },
            suppression: UpdateSuppressionStore(),
            opener: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            }
        )
    }
}
