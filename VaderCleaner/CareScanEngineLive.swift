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
        statsService: SystemStatsService,
        protectionSettings: ProtectionSettingsStore? = nil
    ) -> CareScanEngine.UnitRunners {
        // Previews and tests may omit the store; default arguments evaluate
        // outside the main actor, so the fallback is built here instead.
        let protectionSettings = protectionSettings ?? ProtectionSettingsStore()
        let detector = ClamAVDetector()
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
            similarImages: { onProgress in
                try await SimilarImageScanner().scan(excluding: await excludedURLs(), onProgress: onProgress)
            },
            downloads: { onProgress in
                try await DownloadsScanner().scan(excluding: await excludedURLs(), onProgress: onProgress)
            },
            largeOldFiles: { onProgress in
                try await LargeOldFilesScanner().scan(excluding: await excludedURLs(), onProgress: onProgress)
            },
            // The same sweep the standalone Protection screen runs on Quick.
            // Read per scan (weak capture) so a Settings → Protection change
            // takes effect on the next run, exactly like the exclusions above.
            malware: { [weak protectionSettings] onProgress in
                let scope = await MainActor.run {
                    malwareScanScope(
                        excludeICloud: protectionSettings?.excludeDownloadedICloudFiles
                            ?? ProtectionSettingsStore.defaultExcludeDownloadedICloudFiles
                    )
                }
                let scanner = ClamAVScanner(
                    detector: detector,
                    excludedDirectories: scope.excludedDirectories
                )
                return try await scanner.scan(paths: scope.paths, progress: { _, filesScanned in
                    onProgress(filesScanned)
                })
            },
            installers: {
                await DefaultInstallationFileScanner().scan(excluding: await excludedURLs())
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
                await DefaultUnusedAppScanner().scan(apps: apps, excluding: await excludedURLs())
            },
            unsupportedApps: { apps in
                await DefaultUnsupportedAppScanner().scan(apps: apps)
            },
            appLeftovers: { installedBundleIDs in
                await DefaultAppLeftoverScanner().scan(
                    installedBundleIDs: installedBundleIDs,
                    excluding: await excludedURLs()
                )
            },
            extensions: {
                async let safari = SafariExtensionDiscovery().extensions()
                async let browser = BrowserExtensionDiscovery().extensions()
                async let mail = MailPluginDiscovery().extensions()
                async let internet = InternetPluginDiscovery().extensions()
                return await safari + browser + mail + internet
            },
            backgroundItems: {
                let manager = LaunchAgentManager()
                return manager.userAgents() + manager.systemAgents()
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

    /// What Smart Scan's malware lane covers: the Protection screen's Quick
    /// Scan, resolved through the one function that defines it so the two
    /// surfaces can't drift into scanning different things. Smart Scan stays
    /// on Quick whatever mode Protection is set to — a care scan runs all its
    /// lanes in one pass, and a Deep sweep of `$HOME` would dominate it.
    /// Pinned by `test_malwareScanScope_matchesTheProtectionQuickScan`.
    @MainActor
    static func malwareScanScope(
        excludeICloud: Bool
    ) -> (paths: [URL], excludedDirectories: [String]) {
        MalwareViewModel.scanScope(for: .quick, excludeICloud: excludeICloud)
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
