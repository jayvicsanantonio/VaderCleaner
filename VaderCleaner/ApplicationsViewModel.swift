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
    let installedApps: [AppInfo]
    let availableUpdates: [UpdateInfo]

    /// "We've found N apps on your Mac." headline figure.
    var installedCount: Int { installedApps.count }
    /// Updates card count.
    var updatesCount: Int { availableUpdates.count }
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

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let discoverApps: DiscoverApps
    @ObservationIgnored private let checkUpdates: CheckUpdates
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "ApplicationsViewModel")

    /// Incremented at the start of every scan so a result that resolves after a
    /// newer scan (or a `reset()`) began is dropped instead of overwriting it.
    @ObservationIgnored private var scanGeneration = 0

    init(
        discoverApps: @escaping DiscoverApps,
        checkUpdates: @escaping CheckUpdates
    ) {
        self.discoverApps = discoverApps
        self.checkUpdates = checkUpdates
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

        do {
            let apps = try await discoverApps()
            let updates = await checkUpdates(apps)
            guard scanGeneration == generation else { return }
            phase = .results(ApplicationsScanResult(
                installedApps: apps,
                availableUpdates: updates
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
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "ApplicationsViewModel.live")
        return ApplicationsViewModel(
            discoverApps: {
                try await discovery.installedApps(includingSystemApps: false)
            },
            checkUpdates: { apps in
                await Self.fetchUpdates(for: apps, appStore: appStore, sparkle: sparkle, log: log)
            }
        )
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
