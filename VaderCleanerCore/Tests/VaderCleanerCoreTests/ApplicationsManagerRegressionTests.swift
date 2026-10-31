// ApplicationsManagerRegressionTests.swift
// Pins the Applications Manager fixes across its uninstaller, leftovers, Homebrew, and updater view models, each test driving the real state machine against fakes.

import Foundation
import Testing
@testable import VaderCleanerCore

final class RegressionBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

actor RegressionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

func app(_ name: String, id: String, path: String? = nil) -> AppInfo {
    AppInfo(
        name: name,
        bundleID: id,
        version: "1.0",
        bundleURL: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
        isAppStore: false
    )
}

let noRecycle = AppUninstallerViewModel.RecycleOutcome(bytesFreed: 1, bundlePermanentlyRemoved: false)

@MainActor
func brewVM(_ runner: StubBrewRunner) -> HomebrewViewModel {
    HomebrewViewModel(
        locator: StubBrewLocator(url: URL(fileURLWithPath: "/opt/homebrew/bin/brew")),
        makeRunner: { _ in runner },
        stallTimeout: 1000
    )
}

func outdatedJSON(formulae: [String] = [], casks: [String] = []) -> String {
    func entry(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"installed_versions\":[\"1\"],\"current_version\":\"2\",\"pinned\":false}"
    }
    return "{\"formulae\":[\(formulae.map(entry).joined(separator: ","))],\"casks\":[\(casks.map(entry).joined(separator: ","))]}"
}

@Suite("Applications Manager regressions", .serialized)
@MainActor
struct ApplicationsManagerRegressionTests {

    // MARK: Uninstaller

    @Test("single uninstall removes the app from the batch selection")
    func singleUninstallPrunesSelection() async {
        let a = app("A", id: "com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] }, findFiles: { _ in [] }, recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        vm.select(a.id)
        #expect(await pollUntil { !vm.isLoadingAssociatedFiles })
        await vm.uninstall()
        #expect(vm.apps.isEmpty)
        #expect(vm.uninstallSelection.isEmpty)
        #expect(vm.canUninstallSelection == false)
    }

    @Test("a reload drops selection entries for apps that no longer exist")
    func reloadPrunesSelection() async {
        let a = app("A", id: "com.acme.a")
        let roster = RegressionBox([a])
        let vm = AppUninstallerViewModel(
            discover: { _ in roster.value }, findFiles: { _ in [] }, recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        roster.value = []
        await vm.loadApps()
        #expect(vm.uninstallSelection.isEmpty)
    }

    @Test("uninstalling purges the measured size, and a reinstall is measured again")
    func uninstallPurgesMeasuredSize() async {
        let a = app("A", id: "com.acme.a")
        let roster = RegressionBox([a])
        let measured = RegressionBox(0)
        let vm = AppUninstallerViewModel(
            discover: { _ in roster.value },
            findFiles: { _ in [] },
            measureListMetrics: { apps in
                AsyncStream { continuation in
                    measured.mutate { $0 += apps.count }
                    continuation.yield(Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Int64(10)) }))
                    continuation.finish()
                }
            },
            recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        await vm.loadListMetrics()
        vm.toggleUninstallSelection(a.id)
        await vm.uninstallSelected()
        #expect(vm.listSizes[a.id] == nil)
        await vm.loadApps()
        await vm.loadListMetrics()
        #expect(measured.value == 2)
    }

    @Test("uninstalling one of two copies keeps the shared support files")
    func duplicateCopyKeepsSharedFiles() async {
        let first = app("A", id: "com.acme.a", path: "/Applications/A.app")
        let second = app("A", id: "com.acme.a", path: "/Users/x/Applications/A.app")
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/com.acme.a")
        let recycled = RegressionBox<[URL]>([])
        let vm = AppUninstallerViewModel(
            discover: { _ in [first, second] },
            findFiles: { _ in [AssociatedFile(url: support, sizeBytes: 5, category: .applicationSupport)] },
            recycle: { _, associated in
                recycled.value = associated
                return noRecycle
            }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(first.id)
        await vm.uninstallSelected()
        #expect(vm.apps.map(\.id) == [second.id])
        #expect(recycled.value.isEmpty)
    }

    @Test("the single-app uninstall is locked out while a batch is running")
    func singleUninstallBlockedDuringBatch() async {
        let a = app("A", id: "com.acme.a")
        let b = app("B", id: "com.acme.b")
        let gate = RegressionGate()
        let calls = RegressionBox(0)
        let vm = AppUninstallerViewModel(
            discover: { _ in [a, b] },
            findFiles: { _ in [] },
            recycle: { _, _ in
                calls.mutate { $0 += 1 }
                await gate.wait()
                return noRecycle
            }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        let batch = Task { await vm.uninstallSelected() }
        #expect(await pollUntil { calls.value == 1 })
        vm.select(b.id)
        #expect(await pollUntil { !vm.isLoadingAssociatedFiles })
        #expect(vm.canUninstallSelectedApp == false)
        await gate.open()
        await batch.value
    }

    // MARK: Leftovers and scan

    @Test("a partly recycled leftover group stops claiming the bytes it freed")
    func partialLeftoverTotal() async throws {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(count: 7).write(to: kept)
        defer { try? FileManager.default.removeItem(at: kept) }
        let gone = URL(fileURLWithPath: "/tmp/gone")
        let vm = ApplicationsViewModel(
            discoverApps: { [] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in
                [LeftoverGroup(bundleID: "com.acme.gone", displayName: "gone", urls: [kept, gone], totalBytes: 100)]
            },
            recycleFiles: { _ in [gone] }
        )
        await vm.scan()
        guard case .results(let before) = vm.phase else { Issue.record("no results"); return }
        vm.toggleLeftover(before.leftovers[0])
        await vm.deleteSelectedLeftovers()
        guard case .results(let after) = vm.phase else { Issue.record("no results"); return }
        #expect(after.leftovers.count == 1)
        #expect(after.leftovers[0].totalBytes == 7)
    }

    @Test("reset during a scan drops the scan's late result")
    func resetDropsLateScan() async {
        let gate = RegressionGate()
        let vm = ApplicationsViewModel(
            discoverApps: {
                await gate.wait()
                return []
            },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in [] },
            recycleFiles: { _ in [] }
        )
        let scan = Task { await vm.scan() }
        #expect(await pollUntil { vm.phase == .scanning })
        vm.reset()
        await gate.open()
        await scan.value
        #expect(vm.phase == .idle)
    }

    @Test("an installed variant's base ID is not reported as an orphan")
    func parentIDNotOrphan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("com.acme.App.plist").path, contents: Data())
        let scanner = DefaultAppLeftoverScanner(roots: [(root, .preferences)])
        let groups = await scanner.scan(installedBundleIDs: ["com.acme.App.Pro"])
        #expect(groups.isEmpty)
    }

    @Test("a vendor updater's support files survive while its apps are installed")
    func vendorUpdaterNotOrphan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("com.google.Keystone.Agent.plist").path, contents: Data())
        let scanner = DefaultAppLeftoverScanner(roots: [(root, .preferences)])
        let groups = await scanner.scan(installedBundleIDs: ["com.google.Chrome"])
        #expect(groups.isEmpty)
    }

    // MARK: Homebrew

    @Test("cancelling the formula step stops the cask step")
    func cancelStopsChain() async {
        let runner = StubBrewRunner()
        runner.hangingStreams = ["uninstall wget"]
        let vm = brewVM(runner)
        await vm.load()
        await vm.requestUninstall([
            BrewPackage(name: "wget", kind: .formula, installedVersions: ["1"], isLeaf: true),
            BrewPackage(name: "firefox", kind: .cask, installedVersions: ["1"], isLeaf: true),
        ])
        let task = Task { await vm.confirmUninstall() }
        #expect(await pollUntil { runner.streamingCalls.count == 1 })
        vm.cancelActiveOperation()
        await task.value
        #expect(!runner.streamingCalls.contains(["uninstall", "--cask", "firefox"]))
    }

    @Test("uninstalling a package removes it from the outdated list")
    func uninstallRefreshesOutdated() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(casks: ["firefox"]), standardError: ""
        )
        let vm = brewVM(runner)
        await vm.load()
        await vm.checkUpdates()
        #expect(vm.outdated.map(\.name) == ["firefox"])
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(), standardError: ""
        )
        await vm.requestUninstall([BrewPackage(name: "firefox", kind: .cask, installedVersions: ["1"], isLeaf: true)])
        await vm.confirmUninstall()
        #expect(vm.outdated.isEmpty)
    }

    @Test("upgrading an outdated cask tells brew it is a cask")
    func upgradePassesCaskFlag() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(casks: ["docker"]), standardError: ""
        )
        let vm = brewVM(runner)
        await vm.load()
        await vm.checkUpdates()
        await vm.upgrade(.some(["docker"]))
        #expect(runner.streamingCalls.last?.contains("--cask") == true)
    }

    @Test("a failed outdated check leaves a message the facet can show")
    func failedOutdatedHasMessage() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 1, standardOutput: "", standardError: "boom"
        )
        let vm = brewVM(runner)
        await vm.load()
        await vm.checkUpdates()
        // The facet's banner reads only `manualHandling` and `lastOperationError`.
        #expect(vm.lastOperationError != nil)
    }

    // MARK: Updater

    private func updater(
        apps: [AppInfo] = [],
        tokens: [String: String] = [:],
        suppression: UpdateSuppressionStore? = nil,
        install: AppUpdaterViewModel.Install? = nil
    ) -> AppUpdaterViewModel {
        AppUpdaterViewModel(
            discover: { _ in apps },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in .noResult },
            loadCaskOwnership: {
                CaskOwnershipMap(casks: tokens.map { CaskOwnership(token: $0.value, appNames: [$0.key]) })
            },
            suppression: suppression,
            install: install,
            opener: { _ in }
        )
    }

    @Test("a formula sharing a cask's name doesn't create an update row")
    func formulaNameCollision() async {
        let docker = app("Docker", id: "com.docker.docker")
        let vm = updater(apps: [docker], tokens: ["Docker.app": "docker"])
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([
            BrewOutdatedItem(name: "docker", kind: .formula, installedVersion: "1", candidateVersion: "2", isPinned: false)
        ])
        #expect(vm.availableUpdates.isEmpty)
    }

    @Test("a skipped Homebrew row can be found again in the Skipped list")
    func skippedBrewRowIsReversible() async throws {
        let suite = "audit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let docker = app("Docker", id: "com.docker.docker")
        let vm = updater(apps: [docker], tokens: ["Docker.app": "docker-desktop"], suppression: UpdateSuppressionStore(defaults: defaults))
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([
            BrewOutdatedItem(name: "docker-desktop", kind: .cask, installedVersion: "1", candidateVersion: "2", isPinned: false)
        ])
        let row = try #require(vm.availableUpdates.first)
        vm.skip(row)
        #expect(vm.availableUpdates.isEmpty)
        #expect(vm.skippedUpdates.map(\.bundleID) == ["com.docker.docker"])
    }

    @Test("pressing Update twice installs one copy")
    func doubleUpdateInstallsOnce() async {
        let gate = RegressionGate()
        let installs = RegressionBox(0)
        let vm = updater(install: { _, _, _, _ in
            installs.mutate { $0 += 1 }
            await gate.wait()
            return .installed
        })
        let info = UpdateInfo(
            appName: "A",
            bundleID: "com.acme.a",
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            installedVersion: "1",
            latestVersion: "2",
            source: .sparkle,
            updateURL: URL(string: "https://example.com/a.zip")
        )
        let first = Task { await vm.update([info]) }
        #expect(await pollUntil { installs.value == 1 })
        let second = Task { await vm.update([info]) }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(installs.value == 1)
        await gate.open()
        await first.value
        await second.value
        #expect(installs.value == 1)
    }
}

// MARK: - Removal outcomes and safety

@Suite("Applications Manager removal outcomes", .serialized)
@MainActor
struct ApplicationsManagerRemovalOutcomeTests {

    private enum Failure: Error { case denied }

    @Test("a permanently removed app says so in the result notice")
    func noticeReportsPermanentRemoval() async throws {
        let a = app("A", id: "com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] },
            findFiles: { _ in [] },
            recycle: { _, _ in .init(bytesFreed: 10, bundlePermanentlyRemoved: true) }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        await vm.uninstallSelected()
        let notice = try #require(vm.notice)
        #expect(notice.message.localizedCaseInsensitiveContains("permanently"))
        #expect(notice.isError == false)
        vm.dismissResult()
        #expect(vm.notice == nil)
    }

    @Test("a partly failed batch names the apps it couldn't remove")
    func noticeNamesBatchFailures() async throws {
        let good = app("Good", id: "com.acme.good")
        let bad = app("Bad", id: "com.acme.bad")
        let vm = AppUninstallerViewModel(
            discover: { _ in [good, bad] },
            findFiles: { _ in [] },
            recycle: { url, _ in
                if url.lastPathComponent == "Bad.app" { throw Failure.denied }
                return noRecycle
            }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(good.id)
        vm.toggleUninstallSelection(bad.id)
        await vm.uninstallSelected()
        let notice = try #require(vm.notice)
        #expect(notice.isError)
        #expect(notice.message.contains("Bad"))
        #expect(!notice.message.contains("Good"))
    }

    @Test("a failed uninstall surfaces its message and helper recovery")
    func noticeCarriesFailure() async throws {
        let a = app("A", id: "com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] },
            findFiles: { _ in [] },
            recycle: { _, _ in throw HelperConnectionError.unavailable }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(a.id)
        await vm.uninstallSelected()
        let notice = try #require(vm.notice)
        #expect(notice.isError)
        #expect(notice.offersHelperReinstall)
    }

    @Test("a running app is refused rather than Trashed out from under itself")
    func runningAppRefused() async throws {
        let a = app("A", id: "com.acme.a")
        let recycled = RegressionBox(0)
        let vm = AppUninstallerViewModel(
            discover: { _ in [a] },
            findFiles: { _ in [] },
            recycle: { _, _ in
                recycled.mutate { $0 += 1 }
                return noRecycle
            },
            appIsRunning: { _ in true }
        )
        await vm.loadApps()
        vm.select(a.id)
        #expect(await pollUntil { !vm.isLoadingAssociatedFiles })
        await vm.uninstall()
        #expect(recycled.value == 0)
        #expect(vm.apps.count == 1)
        let single = try #require(vm.notice)
        #expect(single.message.contains("A"))
        #expect(single.isError)

        vm.toggleUninstallSelection(a.id)
        await vm.uninstallSelected()
        #expect(recycled.value == 0)
        #expect(vm.notice?.isError == true)
    }

    @Test("VaderCleaner never offers to uninstall itself")
    func selfExcluded() {
        let me = app("VaderCleaner", id: "com.personal.VaderCleaner")
        let other = app("Other", id: "com.acme.other")
        let listed = AppUninstallerViewModel.uninstallableApps(
            [me, other], selfBundleID: "com.personal.VaderCleaner"
        )
        #expect(listed == [other])
    }

    @Test("the detail view of a duplicated app promises and removes only its bundle")
    func detailOfDuplicateKeepsSharedFiles() async {
        let first = app("A", id: "com.acme.a", path: "/Applications/A.app")
        let second = app("A", id: "com.acme.a", path: "/Users/x/Applications/A.app")
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/com.acme.a")
        let recycled = RegressionBox<[URL]>([URL(fileURLWithPath: "/sentinel")])
        let vm = AppUninstallerViewModel(
            discover: { _ in [first, second] },
            findFiles: { _ in [AssociatedFile(url: support, sizeBytes: 5, category: .applicationSupport)] },
            recycle: { _, associated in
                recycled.value = associated
                return noRecycle
            }
        )
        await vm.loadApps()
        vm.select(first.id)
        #expect(await pollUntil { !vm.isLoadingAssociatedFiles })
        #expect(vm.associatedFilesByCategory.isEmpty)
        await vm.uninstall()
        #expect(recycled.value.isEmpty)
    }

    @Test("selecting both copies still cleans up the shared files once")
    func bothCopiesCleanUp() async {
        let first = app("A", id: "com.acme.a", path: "/Applications/A.app")
        let second = app("A", id: "com.acme.a", path: "/Users/x/Applications/A.app")
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/com.acme.a")
        let recycled = RegressionBox<[[URL]]>([])
        let vm = AppUninstallerViewModel(
            discover: { _ in [first, second] },
            findFiles: { _ in [AssociatedFile(url: support, sizeBytes: 5, category: .applicationSupport)] },
            recycle: { _, associated in
                recycled.mutate { $0.append(associated) }
                return noRecycle
            }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(first.id)
        vm.toggleUninstallSelection(second.id)
        await vm.uninstallSelected()
        #expect(recycled.value == [[], [support]])
    }

    @Test("launch agents are unloaded before their plists move, and only agents")
    func launchAgentsUnloaded() async throws {
        let bundle = URL(fileURLWithPath: "/Applications/A.app")
        let agent = URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.acme.a.plist")
        let prefs = URL(fileURLWithPath: "/Users/x/Library/Preferences/com.acme.a.plist")
        let order = RegressionBox<[String]>([])
        _ = try await AppUninstallerViewModel.recycleWithEscalation(
            bundleURL: bundle,
            associatedURLs: [agent, prefs],
            recycle: { urls in
                order.mutate { $0.append("recycle") }
                return (Set(urls.map(\.path)), nil)
            },
            escalate: { _ in nil },
            sizeFor: { _ in [:] },
            exists: { _ in false },
            unloadLaunchAgents: { urls in
                order.mutate { $0.append("unload:\(urls.map(\.lastPathComponent).joined())") }
            }
        )
        #expect(order.value == ["unload:com.acme.a.plist", "recycle"])
    }

    // MARK: Helper pre-flight

    private func recycleRecordingOrder(
        needsHelper: Bool,
        helperIsReachable: Bool,
        steps: RegressionBox<[String]>
    ) async throws {
        let agent = URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.acme.a.plist")
        _ = try await AppUninstallerViewModel.recycleWithEscalation(
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            associatedURLs: [agent],
            recycle: { urls in
                steps.mutate { $0.append("recycle") }
                return (Set(urls.map(\.path)), nil)
            },
            escalate: { _ in nil },
            sizeFor: { _ in [:] },
            exists: { _ in false },
            unloadLaunchAgents: { _ in steps.mutate { $0.append("unload") } },
            bundleNeedsHelper: { _ in needsHelper },
            helperIsReachable: {
                steps.mutate { $0.append("probe") }
                return helperIsReachable
            }
        )
    }

    @Test("a helper that's down fails the uninstall before anything moves")
    func helperDownFailsBeforeMoving() async {
        let steps = RegressionBox<[String]>([])
        await #expect {
            try await recycleRecordingOrder(needsHelper: true, helperIsReachable: false, steps: steps)
        } throws: { HelperConnectionError.isConnectionFailure($0) }
        #expect(steps.value == ["probe"])
    }

    @Test("a helper that answers lets the uninstall go ahead")
    func helperUpProceeds() async throws {
        let steps = RegressionBox<[String]>([])
        try await recycleRecordingOrder(needsHelper: true, helperIsReachable: true, steps: steps)
        #expect(steps.value == ["probe", "unload", "recycle"])
    }

    @Test("an app the user can move never waits on the helper")
    func movableAppSkipsProbe() async throws {
        let steps = RegressionBox<[String]>([])
        try await recycleRecordingOrder(needsHelper: false, helperIsReachable: false, steps: steps)
        #expect(steps.value == ["unload", "recycle"])
    }

    @Test("a helper that never replies is reported unreachable within the short timeout")
    func probeTimesOutQuickly() async {
        let probe = HelperReachability(helperProvider: { _ in HelperProtocolSpy(defaultReply: .drop) })
        let clock = ContinuousClock()
        let started = clock.now
        let reachable = await probe.probe(timeout: .milliseconds(50))
        #expect(!reachable)
        #expect(started.duration(to: clock.now) < .seconds(5))
    }

    @Test("a bundle the user can't write to needs the helper; a writable or missing one doesn't")
    func detectsBundleNeedingHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("A.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(!AppUninstallerViewModel.needsHelperToRemove(bundle))
        #expect(!AppUninstallerViewModel.needsHelperToRemove(root.appendingPathComponent("Gone.app")))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
        #expect(AppUninstallerViewModel.needsHelperToRemove(bundle))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        #expect(AppUninstallerViewModel.needsHelperToRemove(bundle))
    }

    // MARK: Leftovers and installers

    private func removalVM(
        leftovers: [LeftoverGroup] = [],
        recycle: @escaping ApplicationsViewModel.RecycleFiles
    ) -> ApplicationsViewModel {
        ApplicationsViewModel(
            discoverApps: { [] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in leftovers },
            recycleFiles: recycle
        )
    }

    @Test("files that won't go to the Trash produce a notice")
    func trashFailureNotice() async throws {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        let group = LeftoverGroup(bundleID: "com.acme.gone", displayName: "gone", urls: [a, b], totalBytes: 2)
        let vm = removalVM(leftovers: [group], recycle: { _ in [a] })
        await vm.scan()
        vm.toggleLeftover(group)
        await vm.deleteSelectedLeftovers()
        let notice = try #require(vm.notice)
        #expect(notice.isError)
        #expect(notice.message.contains("1"))
        vm.dismissNotice()
        #expect(vm.notice == nil)
    }

    @Test("a clean removal leaves no notice")
    func cleanRemovalNoNotice() async {
        let a = URL(fileURLWithPath: "/tmp/a")
        let group = LeftoverGroup(bundleID: "com.acme.gone", displayName: "gone", urls: [a], totalBytes: 2)
        let vm = removalVM(leftovers: [group], recycle: { Set($0) })
        await vm.scan()
        vm.toggleLeftover(group)
        await vm.deleteSelectedLeftovers()
        #expect(vm.notice == nil)
    }

    // MARK: Leftover false positives

    private func scanLeftoverPlist(
        _ name: String,
        installed: Set<String>,
        isRegisteredApp: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async throws -> [LeftoverGroup] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("\(name).plist").path, contents: Data())
        let scanner = DefaultAppLeftoverScanner(roots: [(root, .preferences)], isRegisteredApp: isRegisteredApp)
        return await scanner.scan(installedBundleIDs: installed)
    }

    @Test("an app Launch Services knows about isn't an orphan wherever it lives")
    func registeredAppNotOrphan() async throws {
        let groups = try await scanLeftoverPlist(
            "com.acme.Elsewhere", installed: [], isRegisteredApp: { $0 == "com.acme.Elsewhere" }
        )
        #expect(groups.isEmpty)
    }

    @Test("bundle ID matching ignores case, as Launch Services does")
    func caseInsensitiveCoverage() {
        #expect(DefaultAppLeftoverScanner.isCoveredByInstalled("COM.acme.app", installed: ["com.acme.App"]))
    }

    @Test("a genuine orphan is still found")
    func genuineOrphanStillFlagged() async throws {
        let groups = try await scanLeftoverPlist("com.acme.Gone", installed: ["com.acme.Other"])
        #expect(groups.map(\.bundleID) == ["com.acme.Gone"])
    }

    @Test(arguments: ["org.sparkle-project.Sparkle", "com.microsoft.autoupdate2", "com.personal.VaderCleaner"])
    func sharedInfrastructureNeverFlagged(id: String) async throws {
        let groups = try await scanLeftoverPlist(id, installed: [])
        #expect(groups.isEmpty)
    }

    // MARK: Extensions

    private func extensionItem(_ path: String) -> ExtensionItem {
        ExtensionItem(
            name: "E", path: URL(fileURLWithPath: path), bundleID: nil,
            type: .chromeExtension, isEnabled: true, size: 1
        )
    }

    @Test("a user extension goes to the Trash and a refusal is an error")
    func extensionGoesToTrash() async throws {
        let item = extensionItem("/Users/x/Library/Application Support/Google/Chrome/Default/Extensions/abc")
        let helperCalls = RegressionBox(0)
        let helper: @Sendable (String) async throws -> Void = { _ in helperCalls.mutate { $0 += 1 } }

        try await ExtensionsManagerViewModel.removeItem(item, recycle: { Set($0) }, deleteViaHelper: helper)
        #expect(helperCalls.value == 0)

        await #expect(throws: (any Error).self) {
            try await ExtensionsManagerViewModel.removeItem(item, recycle: { _ in [] }, deleteViaHelper: helper)
        }
    }

    @Test("a system extension routes through the helper and is called out as permanent")
    func systemExtensionIsPermanent() async throws {
        let system = extensionItem("/Library/Mail/Bundles/E.mailbundle")
        let user = extensionItem("/Users/x/Library/Mail/Bundles/E.mailbundle")
        let helperPaths = RegressionBox<[String]>([])
        try await ExtensionsManagerViewModel.removeItem(
            system,
            recycle: { _ in Issue.record("must not recycle"); return [] },
            deleteViaHelper: { path in helperPaths.mutate { $0.append(path) } }
        )
        #expect(helperPaths.value == [system.path.path])
        let vm = ExtensionsManagerViewModel(discover: { [system, user] }, remove: { _ in })
        await vm.refresh()
        #expect(vm.includesPermanentRemoval([system.id, user.id]))
        #expect(!vm.includesPermanentRemoval([user.id]))
    }

    @Test("a failed extension removal produces a dismissible notice")
    func extensionFailureNotice() async throws {
        let item = extensionItem("/Users/x/E")
        let vm = ExtensionsManagerViewModel(discover: { [item] }, remove: { _ in throw Failure.denied })
        await vm.refresh()
        await vm.removeSelected([item.id])
        let notice = try #require(vm.notice)
        #expect(notice.isError)
        vm.dismissResult()
        #expect(vm.notice == nil)
    }

    // MARK: Homebrew

    @Test("a failed inventory load is reported and doesn't get wiped by the update check")
    func failedLoadSurvivesUpdateCheck() async throws {
        let runner = StubBrewRunner()
        runner.throwingCaptures = ["list"]
        let vm = brewVM(runner)
        await vm.loadIfNeeded()
        await vm.checkUpdatesIfNeeded()
        #expect(vm.lastOperationError != nil)
        guard case .failed = vm.phase else {
            Issue.record("expected the load failure to stand")
            return
        }
        #expect(!runner.capturingCalls.contains(["update"]))
    }

    @Test("refresh retries after a failed load")
    func refreshRetries() async {
        let runner = StubBrewRunner()
        runner.throwingCaptures = ["list"]
        let vm = brewVM(runner)
        await vm.loadIfNeeded()
        runner.throwingCaptures = []
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(), standardError: ""
        )
        await vm.refresh()
        #expect(vm.phase == .ready)
        #expect(vm.lastOperationError == nil)
        #expect(runner.capturingCalls.contains(["update"]))
    }
}
