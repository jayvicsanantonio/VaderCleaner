// CareScanEngineLive.swift
// Production wiring for CareScanEngine: builds the UnitRunners from the same collaborators the standalone sections use, so Smart Scan and the sections never diverge.

import AppKit
import Foundation

extension CareScanEngine.UnitRunners {

    /// The live runners. Each closure reuses the exact collaborator the
    /// matching standalone section wires (`SystemJunkViewModel.live`,
    /// `MalwareViewModel.live`, `ApplicationsViewModel.live`, …), so the two
    /// surfaces always produce identical results for the same Mac.
    ///
    /// Exclusions are read per scan (weak capture) so a freshly-added
    /// Preferences exclusion takes effect on the next run. The stats service
    /// is the app-scoped polling instance — the snapshot closure only reads
    /// its already-published cheap values and never constructs a second
    /// service or spawns the slow SMART/FileVault probes.
    @MainActor
    static func live(
        exclusions: ExclusionsStore,
        webDevScanScope: WebDevScanScopeStore? = nil,
        statsService: SystemStatsService
    ) -> CareScanEngine.UnitRunners {
        let malwareScanner = ClamAVScanner(detector: ClamAVDetector())
        let quickScanPaths = MalwareViewModel.defaultQuickScanPaths()
        let excludedURLs: @Sendable () async -> [URL] = { [weak exclusions] in
            await MainActor.run {
                (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
            }
        }
        let projectScanRoots: @Sendable () async -> [URL]? = { [weak webDevScanScope] in
            await MainActor.run { webDevScanScope?.scanRoots }
        }

        return CareScanEngine.UnitRunners(
            junk: { onProgress in
                let excluded = await excludedURLs()
                let roots = await projectScanRoots()
                return try await SystemJunkScanner.live(projectScanRoots: roots)
                    .scan(excluding: excluded, onProgress: onProgress)
            },
            duplicates: { onProgress in
                try await DuplicateScanner().scan(excluding: await excludedURLs(), onProgress: onProgress)
            },
            largeOldFiles: { onProgress in
                try await LargeOldFilesScanner().scan(excluding: await excludedURLs(), onProgress: onProgress)
            },
            // Scope matches the standalone Protection screen's Quick Scan —
            // the high-risk home subdirectories rather than all of $HOME,
            // which dominated Smart Scan's wall-clock time.
            malware: { onProgress in
                try await malwareScanner.scan(paths: quickScanPaths, progress: { _, filesScanned in
                    onProgress(filesScanned)
                })
            },
            installers: {
                await DefaultInstallationFileScanner().scan()
            },
            installedApps: {
                try await DefaultAppDiscovery().installedApps(includingSystemApps: false)
            },
            appUpdates: { apps, onProgress in
                await UpdateProbe.live().availableUpdates(for: apps, onProgress: { checked, _ in
                    onProgress(checked)
                })
            },
            unusedApps: { apps in
                await DefaultUnusedAppScanner().scan(apps: apps)
            },
            appLeftovers: { installedBundleIDs in
                await DefaultAppLeftoverScanner().scan(installedBundleIDs: installedBundleIDs)
            },
            loginItems: {
                await MainActor.run { LoginItemsManager.live().items() }
            },
            dueMaintenanceTaskIDs: {
                Self.dueMaintenanceTaskIDs(
                    runLog: MaintenanceRunLog(),
                    // `periodic` was removed in macOS 26; when absent the
                    // scripts task is neither counted due nor ever run.
                    maintenanceScriptsAvailable: FileManager.default.fileExists(atPath: "/usr/sbin/periodic")
                )
            },
            browserPrivacy: {
                let inspector = BrowserPrivacyInspector(pathProvider: DefaultBrowserDataPathProvider())
                let browsers = DefaultBrowserDetector().installedBrowsers()
                return await Self.browserPrivacySummaries(browsers: browsers) { category, browser in
                    await inspector.count(for: category, browser: browser)
                }
            },
            healthSnapshot: { [weak statsService] in
                await MainActor.run {
                    guard let statsService else { return nil }
                    return CareHealthSnapshot(
                        disk: statsService.diskSpace,
                        memoryPressure: statsService.ramUsage.pressureLevel,
                        smart: statsService.diskSMARTStatus,
                        battery: statsService.batteryAvailability
                    )
                }
            }
        )
    }

    /// The maintenance-cocktail task ids currently due: the same catalog and
    /// staleness window the Performance dashboard counts, gated on `periodic`
    /// existing so a task that can't run is never reported as due.
    static func dueMaintenanceTaskIDs(
        runLog: MaintenanceRunLog,
        maintenanceScriptsAvailable: Bool,
        now: Date = Date()
    ) -> [String] {
        let availableIDs = MaintenanceTask.maintenanceCocktailKinds
            .filter { maintenanceScriptsAvailable || $0 != .runMaintenanceScripts }
            .map(\.rawValue)
        return runLog.staleTaskIDs(among: availableIDs, now: now)
    }

    /// Per-browser privacy counts across every Protection category. Zero
    /// counts are dropped so a summary only carries what actually exists;
    /// browsers with nothing counted disappear entirely.
    static func browserPrivacySummaries(
        browsers: [Browser],
        count: (ProtectionPrivacyCategory, Browser) async -> Int
    ) async -> [BrowserPrivacySummary] {
        var summaries: [BrowserPrivacySummary] = []
        for browser in browsers {
            var counts: [ProtectionPrivacyCategory: Int] = [:]
            for category in ProtectionPrivacyCategory.allCases {
                let value = await count(category, browser)
                if value > 0 { counts[category] = value }
            }
            if !counts.isEmpty {
                summaries.append(BrowserPrivacySummary(browser: browser, counts: counts))
            }
        }
        return summaries
    }
}
