// ApplicationsManagerPaneSyncTests.swift
// Pins how the Applications Manager keeps its panes in step: removals reaching every list, refreshes re-reading the disk, and Homebrew changes reaching the Updater and dashboard.

import Foundation
import Testing
@testable import VaderCleanerCore

// MARK: - Staying in step across panes

@Suite("Applications Manager pane sync", .serialized)
@MainActor
struct ApplicationsManagerPaneSyncTests {

    private func scanVM(
        apps: [AppInfo],
        unused: [UnusedApp] = [],
        unsupported: [UnsupportedApp] = [],
        updates: [UpdateInfo] = [],
        recycle: @escaping ApplicationsViewModel.RecycleFiles = { Set($0) }
    ) -> ApplicationsViewModel {
        ApplicationsViewModel(
            discoverApps: { apps },
            checkUpdates: { _ in updates },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in unsupported },
            scanUnusedApps: { _ in unused },
            scanLeftovers: { _ in [] },
            recycleFiles: recycle
        )
    }

    private func update(for app: AppInfo, source: UpdateSource = .sparkle) -> UpdateInfo {
        UpdateInfo(
            appName: app.name, bundleID: app.bundleID, bundleURL: app.bundleURL,
            installedVersion: "1", latestVersion: "2", source: source,
            updateURL: URL(string: "https://example.com/a.zip")
        )
    }

    @Test("an uninstall is reported so the other panes can drop the app")
    func uninstallReportsRemovedIDs() async {
        let a = app("A", id: "com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] }, findFiles: { _ in [] }, recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        await vm.uninstallSelected()
        #expect(vm.removedAppIDs == [a.id])
    }

    @Test("forgetting apps prunes every count on the dashboard")
    func scanResultForgetsApps() async throws {
        let a = app("A", id: "com.acme.a")
        let b = app("B", id: "com.acme.b")
        let vm = scanVM(
            apps: [a, b],
            unused: [UnusedApp(app: a, lastUsedDate: .distantPast, sizeBytes: 1)],
            unsupported: [UnsupportedApp(app: a, reason: .incompatibleArchitecture)],
            updates: [update(for: a)]
        )
        await vm.scan()
        vm.forgetApps([a.id])
        guard case .results(let result) = vm.phase else { Issue.record("no results"); return }
        #expect(result.installedCount == 1)
        #expect(result.unusedAppsCount == 0)
        #expect(result.unsupportedAppsCount == 0)
        #expect(result.updatesCount == 0)
    }

    @Test("trashing an unsupported app is reported to the other panes")
    func unsupportedRemovalReported() async {
        let a = app("A", id: "com.acme.a")
        let entry = UnsupportedApp(app: a, reason: .incompatibleArchitecture)
        let vm = scanVM(apps: [a], unsupported: [entry])
        await vm.scan()
        vm.toggleUnsupportedApp(entry)
        await vm.deleteSelectedUnsupportedApps()
        #expect(vm.removedAppIDs == [a.id])
    }

    @Test("a fresh scan starts a new removal record")
    func scanClearsRemovedIDs() async {
        let a = app("A", id: "com.acme.a")
        let entry = UnsupportedApp(app: a, reason: .incompatibleArchitecture)
        let vm = scanVM(apps: [a], unsupported: [entry])
        await vm.scan()
        vm.toggleUnsupportedApp(entry)
        await vm.deleteSelectedUnsupportedApps()
        await vm.scan()
        #expect(vm.removedAppIDs.isEmpty)
    }

    @Test("the dashboard's update list can follow the Updater's")
    func dashboardFollowsUpdater() async throws {
        let a = app("A", id: "com.acme.a")
        let vm = scanVM(apps: [a])
        await vm.scan()
        vm.setAvailableUpdates([update(for: a, source: .homebrew)])
        guard case .results(let result) = vm.phase else { Issue.record("no results"); return }
        #expect(result.updatesCount == 1)
    }

    @Test("the Uninstaller drops an app another pane removed")
    func uninstallerForgetsApps() async {
        let a = app("A", id: "com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] }, findFiles: { _ in [] }, recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        vm.forgetApps([a.id])
        #expect(vm.apps.isEmpty)
        #expect(vm.uninstallSelection.isEmpty)
        #expect(vm.removedAppIDs.isEmpty)
    }

    @Test("refreshing re-reads the disk rather than reusing session caches")
    func uninstallerRefreshInvalidatesCaches() async {
        let a = app("A", id: "com.acme.a")
        let finds = RegressionBox(0)
        let measures = RegressionBox(0)
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] },
            findFiles: { _ in
                finds.mutate { $0 += 1 }
                return []
            },
            measureListMetrics: { apps in
                AsyncStream { continuation in
                    measures.mutate { $0 += 1 }
                    continuation.yield(Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Int64(1)) }))
                    continuation.finish()
                }
            },
            recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        await vm.loadListMetrics()
        vm.select(a.id)
        #expect(await pollUntil { finds.value == 1 && !vm.isLoadingAssociatedFiles })
        let epoch = vm.listMetricsEpoch
        await vm.refresh()
        #expect(vm.listMetricsEpoch != epoch)
        await vm.loadListMetrics()
        #expect(measures.value == 2)
        vm.select(a.id)
        #expect(await pollUntil { finds.value == 2 })
    }

    private func updater(apps: [AppInfo], update: UpdateInfo?) -> AppUpdaterViewModel {
        AppUpdaterViewModel(
            discover: { _ in apps },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in
                update.map { .found(SparkleAppcastItem(shortVersion: $0.latestVersion, version: nil, downloadURL: $0.updateURL!)) } ?? .noResult
            },
            opener: { _ in }
        )
    }

    @Test("the Updater drops a removed app's row and coverage")
    func updaterForgetsApps() async {
        let a = app("A", id: "com.acme.a")
        let vm = updater(apps: [a], update: update(for: a))
        await vm.checkForUpdates()
        #expect(vm.availableUpdates.count == 1)
        #expect(vm.coverage.total == 1)
        vm.forgetApps([a.id])
        #expect(vm.availableUpdates.isEmpty)
        #expect(vm.coverage.total == 0)
    }

    @Test("a brew uninstall is counted so other panes can re-read the app list")
    func brewUninstallCounted() async {
        let runner = StubBrewRunner()
        let vm = brewVM(runner)
        await vm.load()
        #expect(vm.completedUninstallCount == 0)
        await vm.requestUninstall([BrewPackage(name: "firefox", kind: .cask, installedVersions: ["1"], isLeaf: true)])
        await vm.confirmUninstall()
        #expect(vm.completedUninstallCount == 1)
    }

    @Test("an upgrade refreshes the installed versions")
    func upgradeRefreshesInventory() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(formulae: ["wget"]), standardError: ""
        )
        runner.captures["list --formula --versions"] = BrewResult(
            terminationStatus: 0, standardOutput: "wget 1\n", standardError: ""
        )
        let vm = brewVM(runner)
        await vm.load()
        await vm.checkUpdates()
        runner.captures["list --formula --versions"] = BrewResult(
            terminationStatus: 0, standardOutput: "wget 2\n", standardError: ""
        )
        await vm.upgrade(.some(["wget"]))
        #expect(vm.inventory.first?.installedVersions == ["2"])
    }

    @Test("a selected same-named formula and cask are each upgraded as what they are")
    func upgradeItemsSplitsByKind() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(formulae: ["docker"], casks: ["docker"]), standardError: ""
        )
        let vm = brewVM(runner)
        await vm.load()
        await vm.checkUpdates()
        let cask = vm.outdated.filter { $0.kind == .cask }
        await vm.upgrade(.items(cask))
        #expect(runner.streamingCalls.last == ["upgrade", "--cask", "docker"])
        await vm.upgrade(.items(vm.outdated.filter { $0.kind == .formula }))
        #expect(runner.streamingCalls.last == ["upgrade", "docker"])
    }

    @Test("the dashboard's list merges outdated casks the way the Updater does")
    func dashboardUpdatesIncludeCasks() {
        let cask = app("Docker", id: "com.docker.docker")
        let direct = app("A", id: "com.acme.a")
        let results = [
            UpdateProbeResult(app: cask, outcome: .skipped(.homebrew(token: "docker-desktop"))),
            UpdateProbeResult(app: direct, outcome: .update(update(for: direct))),
        ]
        let rows = UpdateProbe.combinedUpdates(
            results: results,
            outdated: [BrewOutdatedItem(name: "docker-desktop", kind: .cask, installedVersion: "1", candidateVersion: "2", isPinned: false)],
            declined: UpdateSuppressionSnapshot()
        )
        #expect(rows.map(\.appName) == ["A", "Docker"])
        #expect(rows[1].source == .homebrew)
    }
}
