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

    private(set) var phase: Phase = .idle
    private(set) var availableUpdates: [UpdateInfo] = []

    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let checkAppStore: CheckAppStore
    @ObservationIgnored private let checkSparkle: CheckSparkle
    @ObservationIgnored private let opener: Opener
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "AppUpdaterViewModel")

    /// Monotonic counter — a second `checkForUpdates()` invalidates the
    /// older results so a slow first pass can't overwrite a fresh second
    /// pass with stale data. Same pattern as `AppUninstallerViewModel`.
    @ObservationIgnored private var checkGeneration: Int = 0

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
            // The bounded-concurrency fan-out and per-app channel routing
            // live in `UpdateProbe`, shared with the Applications dashboard
            // and Smart Scan so all three surfaces produce identical update
            // lists.
            let probe = UpdateProbe(
                checkAppStore: checkAppStore,
                checkSparkle: checkSparkle
            )
            let outcomes = await probe.outcomes(for: apps)
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
                case .skipped:
                    // No request was made — neither evidence the
                    // network is up nor that it is down.
                    break
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
        return AppUpdaterViewModel(
            discover: { includingSystemApps in
                try await discovery.installedApps(includingSystemApps: includingSystemApps)
            },
            checkAppStore: UpdateProbe.liveAppStoreCheck(),
            checkSparkle: UpdateProbe.liveSparkleCheck(),
            opener: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            }
        )
    }
}
