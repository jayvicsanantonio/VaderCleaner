// ApplicationsViewModelTests.swift
// Drives every ApplicationsViewModel transition (idle → scanning → results / failed) and pins its ScanCoordinating projection, all via injected closures.

import XCTest
@testable import VaderCleaner

@MainActor
final class ApplicationsViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeApp(
        name: String,
        bundleID: String,
        path: String,
        version: String? = "1.0",
        isAppStore: Bool = false
    ) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: version,
            bundleURL: URL(fileURLWithPath: path),
            isAppStore: isAppStore
        )
    }

    private func makeUpdate(name: String, bundleID: String, path: String) -> UpdateInfo {
        UpdateInfo(
            appName: name,
            bundleID: bundleID,
            bundleURL: URL(fileURLWithPath: path),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .appStore,
            updateURL: URL(string: "https://apps.apple.com/app/id1")!
        )
    }

    nonisolated private func makeInstaller(name: String, size: Int64, kind: InstallationFileKind = .diskImage) -> InstallationFile {
        InstallationFile(
            url: URL(fileURLWithPath: "/Users/test/Downloads/\(name)"),
            name: name,
            sizeBytes: size,
            kind: kind
        )
    }

    nonisolated private func makeUnsupported(name: String, bundleID: String) -> UnsupportedApp {
        UnsupportedApp(
            app: AppInfo(
                name: name,
                bundleID: bundleID,
                version: "1.0",
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                isAppStore: false
            ),
            reason: .incompatibleArchitecture
        )
    }

    nonisolated private func makeUnused(name: String, bundleID: String) -> UnusedApp {
        UnusedApp(
            app: AppInfo(
                name: name,
                bundleID: bundleID,
                version: "1.0",
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                isAppStore: false
            ),
            lastUsedDate: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    /// Builds a view-model with injected collaborators. Sub-scans default to
    /// empty and recycling to "removes everything asked" so the existing tests
    /// stay focused on the discover → update path.
    private func makeViewModel(
        discover: @escaping ApplicationsViewModel.DiscoverApps,
        check: @escaping ApplicationsViewModel.CheckUpdates = { _ in [] },
        installers: @escaping ApplicationsViewModel.ScanInstallationFiles = { [] },
        unsupported: @escaping ApplicationsViewModel.ScanUnsupportedApps = { _ in [] },
        unused: @escaping ApplicationsViewModel.ScanUnusedApps = { _ in [] },
        recycle: @escaping ApplicationsViewModel.RecycleFiles = { Set($0) }
    ) -> ApplicationsViewModel {
        ApplicationsViewModel(
            discoverApps: discover,
            checkUpdates: check,
            scanInstallationFiles: installers,
            scanUnsupportedApps: unsupported,
            scanUnusedApps: unused,
            recycleFiles: recycle
        )
    }

    // MARK: - Initial state

    func test_initialPhase_isIdle_andPresentsIntro() {
        let vm = makeViewModel(discover: { [] })
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.scanPresentation, .intro)
    }

    // MARK: - Happy path

    func test_scan_landsResultsWithAppsAndUpdates() async {
        let apps = [
            makeApp(name: "Acme", bundleID: "com.acme.app", path: "/Applications/Acme.app"),
            makeApp(name: "Beta", bundleID: "com.beta.app", path: "/Applications/Beta.app"),
        ]
        let updates = [makeUpdate(name: "Acme", bundleID: "com.acme.app", path: "/Applications/Acme.app")]
        let vm = makeViewModel(discover: { apps }, check: { _ in updates })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.installedApps, apps)
        XCTAssertEqual(result.availableUpdates, updates)
        XCTAssertEqual(result.installedCount, 2)
        XCTAssertEqual(result.updatesCount, 1)
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_scan_passesDiscoveredAppsToTheUpdateChecker() async {
        let apps = [makeApp(name: "Acme", bundleID: "com.acme.app", path: "/Applications/Acme.app")]
        var received: [AppInfo] = []
        let vm = makeViewModel(
            discover: { apps },
            check: { discovered in
                received = discovered
                return []
            }
        )

        await vm.scan()

        XCTAssertEqual(received, apps, "The update checker must receive the discovered apps")
    }

    func test_scan_withNoUpdates_stillLandsResults() async {
        let apps = [makeApp(name: "Acme", bundleID: "com.acme.app", path: "/Applications/Acme.app")]
        let vm = makeViewModel(discover: { apps }, check: { _ in [] })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertTrue(result.availableUpdates.isEmpty)
        XCTAssertEqual(result.updatesCount, 0)
    }

    // MARK: - Failure

    func test_scan_whenDiscoveryThrows_landsFailed() async {
        struct DiscoveryError: Error {}
        let vm = makeViewModel(discover: { throw DiscoveryError() })

        await vm.scan()

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
        // A failed scan still shows the section's own detail UI (the failed
        // state), not the intro.
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    // MARK: - Working projection

    func test_scanPresentation_isWorkingWhileScanning() async {
        // Gate the discovery so the scan parks in `.scanning` long enough to
        // observe the projection before it resolves.
        let gate = AsyncGate()
        let vm = makeViewModel(discover: {
            await gate.wait()
            return []
        })

        let task = Task { await vm.scan() }
        // Yield until the synchronous `phase = .scanning` write lands.
        while vm.phase != .scanning { await Task.yield() }
        XCTAssertEqual(vm.scanPresentation, .working)

        await gate.open()
        await task.value
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    // MARK: - Re-entrancy

    func test_secondScanWhileScanning_isIgnored() async {
        let gate = AsyncGate()
        var discoverCalls = 0
        let vm = makeViewModel(discover: {
            discoverCalls += 1
            await gate.wait()
            return []
        })

        let first = Task { await vm.scan() }
        while vm.phase != .scanning { await Task.yield() }
        // A second scan while the first is in flight must be a no-op — the
        // phase is still `.scanning` and it returns without starting work.
        await vm.scan()
        XCTAssertEqual(vm.phase, .scanning, "A re-entrant scan must not change the phase")

        await gate.open()
        await first.value

        // Asserted after completion (not mid-flight) so it doesn't depend on
        // exactly when the first scan reaches discovery: across both calls,
        // discovery must have run exactly once.
        XCTAssertEqual(discoverCalls, 1, "A re-entrant scan must not start a second discovery")
    }

    // MARK: - Reset

    func test_reset_returnsToIdle() async {
        let vm = makeViewModel(discover: { [] })
        await vm.scan()
        XCTAssertEqual(vm.scanPresentation, .results)

        vm.reset()

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.scanPresentation, .intro)
    }

    // MARK: - Installation files

    func test_scan_carriesInstallationFilesIntoResults() async {
        let installers = [
            makeInstaller(name: "Big.dmg", size: 5_000),
            makeInstaller(name: "Small.pkg", size: 100, kind: .package),
        ]
        let vm = makeViewModel(discover: { [] }, installers: { installers })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.installationFiles, installers)
        XCTAssertEqual(result.installationFilesCount, 2)
        XCTAssertEqual(result.installationFilesTotalBytes, 5_100)
    }

    func test_installationFileSelection_isEmptyAfterScan() async {
        let vm = makeViewModel(
            discover: { [] },
            installers: { [self.makeInstaller(name: "Big.dmg", size: 5_000)] }
        )
        await vm.scan()
        XCTAssertTrue(vm.installationFileSelection.isEmpty,
                      "Destructive removal is opt-in, so nothing starts selected")
        XCTAssertFalse(vm.canRemoveInstallationFiles)
    }

    func test_toggleAndSelectAll_driveSelection() async {
        let a = makeInstaller(name: "A.dmg", size: 5_000)
        let b = makeInstaller(name: "B.pkg", size: 100, kind: .package)
        let vm = makeViewModel(discover: { [] }, installers: { [a, b] })
        await vm.scan()

        vm.toggleInstallationFile(a)
        XCTAssertTrue(vm.isInstallationFileSelected(a))
        XCTAssertFalse(vm.isInstallationFileSelected(b))
        XCTAssertTrue(vm.canRemoveInstallationFiles)

        vm.selectAllInstallationFiles()
        XCTAssertTrue(vm.isInstallationFileSelected(a))
        XCTAssertTrue(vm.isInstallationFileSelected(b))

        vm.clearInstallationFileSelection()
        XCTAssertTrue(vm.installationFileSelection.isEmpty)
    }

    func test_deleteSelectedInstallationFiles_removesRecycledAndRebuildsPayload() async {
        let a = makeInstaller(name: "A.dmg", size: 5_000)
        let b = makeInstaller(name: "B.pkg", size: 100, kind: .package)
        var recycled: [URL] = []
        let vm = makeViewModel(
            discover: { [] },
            installers: { [a, b] },
            recycle: { urls in
                recycled = urls
                return Set(urls)
            }
        )
        await vm.scan()
        vm.toggleInstallationFile(a)

        await vm.deleteSelectedInstallationFiles()

        XCTAssertEqual(recycled, [a.url], "Only the selected installer is recycled")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.installationFiles, [b],
                       "The recycled installer must be dropped from the payload")
        XCTAssertFalse(vm.installationFileSelection.contains(a.url))
        XCTAssertFalse(vm.isRemovingInstallationFiles)
    }

    func test_deleteSelectedInstallationFiles_keepsFilesThatFailedToRecycle() async {
        let a = makeInstaller(name: "A.dmg", size: 5_000)
        let b = makeInstaller(name: "B.pkg", size: 100, kind: .package)
        let vm = makeViewModel(
            discover: { [] },
            installers: { [a, b] },
            // The recycler only manages to Trash one of the two selected.
            recycle: { _ in [a.url] }
        )
        await vm.scan()
        vm.selectAllInstallationFiles()

        await vm.deleteSelectedInstallationFiles()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.installationFiles, [b],
                       "A file the recycler couldn't move must stay in the list")
        XCTAssertTrue(vm.installationFileSelection.contains(b.url),
                      "The still-present file's selection survives so the user can retry")
    }

    func test_deleteSelectedInstallationFiles_withNoSelection_isNoOp() async {
        var recycleCalls = 0
        let vm = makeViewModel(
            discover: { [] },
            installers: { [self.makeInstaller(name: "A.dmg", size: 5_000)] },
            recycle: { urls in recycleCalls += 1; return Set(urls) }
        )
        await vm.scan()

        await vm.deleteSelectedInstallationFiles()

        XCTAssertEqual(recycleCalls, 0, "Nothing selected → the recycler is never called")
    }

    // MARK: - Unsupported apps

    func test_scan_carriesUnsupportedAppsIntoResults() async {
        let unsupported = [
            makeUnsupported(name: "Old32Bit", bundleID: "com.legacy.app"),
        ]
        let vm = makeViewModel(discover: { [] }, unsupported: { _ in unsupported })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.unsupportedApps, unsupported)
        XCTAssertEqual(result.unsupportedAppsCount, 1)
    }

    func test_scan_passesDiscoveredAppsToTheUnsupportedScan() async {
        let apps = [makeApp(name: "Acme", bundleID: "com.acme.app", path: "/Applications/Acme.app")]
        var received: [AppInfo] = []
        let vm = makeViewModel(
            discover: { apps },
            unsupported: { discovered in
                received = discovered
                return []
            }
        )

        await vm.scan()

        XCTAssertEqual(received, apps, "The unsupported scan must receive the discovered apps")
    }

    func test_unsupportedAppSelection_isEmptyAfterScan() async {
        let vm = makeViewModel(
            discover: { [] },
            unsupported: { _ in [self.makeUnsupported(name: "Old", bundleID: "com.old.app")] }
        )
        await vm.scan()
        XCTAssertTrue(vm.unsupportedAppSelection.isEmpty)
        XCTAssertFalse(vm.canRemoveUnsupportedApps)
    }

    func test_deleteSelectedUnsupportedApps_recyclesBundlesAndRebuildsPayload() async {
        let a = makeUnsupported(name: "Old", bundleID: "com.old.app")
        let b = makeUnsupported(name: "Ancient", bundleID: "com.ancient.app")
        var recycled: [URL] = []
        let vm = makeViewModel(
            discover: { [] },
            unsupported: { _ in [a, b] },
            recycle: { urls in recycled = urls; return Set(urls) }
        )
        await vm.scan()
        vm.toggleUnsupportedApp(a)

        await vm.deleteSelectedUnsupportedApps()

        XCTAssertEqual(recycled, [a.app.bundleURL], "Only the selected app bundle is recycled")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.unsupportedApps, [b],
                       "The recycled app must be dropped from the payload")
        XCTAssertFalse(vm.isRemovingUnsupportedApps)
    }

    func test_deleteSelectedUnsupportedApps_keepsBundlesThatFailedToRecycle() async {
        let a = makeUnsupported(name: "Old", bundleID: "com.old.app")
        let b = makeUnsupported(name: "Ancient", bundleID: "com.ancient.app")
        let vm = makeViewModel(
            discover: { [] },
            unsupported: { _ in [a, b] },
            // The recycler (e.g. a root-owned bundle) only manages to move one.
            recycle: { _ in [a.app.bundleURL] }
        )
        await vm.scan()
        vm.selectAllUnsupportedApps()

        await vm.deleteSelectedUnsupportedApps()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.unsupportedApps, [b],
                       "A bundle the recycler couldn't move must stay in the list")
        XCTAssertTrue(vm.unsupportedAppSelection.contains(b.app.bundleURL))
    }

    func test_installationFileDelete_preservesUnsupportedApps() async {
        // Removing an installer must not drop the unsupported-apps payload.
        let installer = makeInstaller(name: "A.dmg", size: 5_000)
        let unsupported = makeUnsupported(name: "Old", bundleID: "com.old.app")
        let vm = makeViewModel(
            discover: { [] },
            installers: { [installer] },
            unsupported: { _ in [unsupported] }
        )
        await vm.scan()
        vm.toggleInstallationFile(installer)

        await vm.deleteSelectedInstallationFiles()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertTrue(result.installationFiles.isEmpty)
        XCTAssertEqual(result.unsupportedApps, [unsupported],
                       "Unrelated payload must survive an installer delete")
    }

    // MARK: - Unused apps

    func test_scan_carriesUnusedAppsIntoResults() async {
        let unused = [makeUnused(name: "Dusty", bundleID: "com.dusty.app")]
        let vm = makeViewModel(discover: { [] }, unused: { _ in unused })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.unusedApps, unused)
        XCTAssertEqual(result.unusedAppsCount, 1)
    }

    func test_scan_passesDiscoveredAppsToTheUnusedScan() async {
        let apps = [makeApp(name: "Acme", bundleID: "com.acme.app", path: "/Applications/Acme.app")]
        var received: [AppInfo] = []
        let vm = makeViewModel(
            discover: { apps },
            unused: { discovered in
                received = discovered
                return []
            }
        )

        await vm.scan()

        XCTAssertEqual(received, apps, "The unused scan must receive the discovered apps")
    }

    func test_deleteSelectedUnusedApps_recyclesBundlesAndRebuildsPayload() async {
        let a = makeUnused(name: "Dusty", bundleID: "com.dusty.app")
        let b = makeUnused(name: "Stale", bundleID: "com.stale.app")
        var recycled: [URL] = []
        let vm = makeViewModel(
            discover: { [] },
            unused: { _ in [a, b] },
            recycle: { urls in recycled = urls; return Set(urls) }
        )
        await vm.scan()
        vm.toggleUnusedApp(a)

        await vm.deleteSelectedUnusedApps()

        XCTAssertEqual(recycled, [a.app.bundleURL], "Only the selected app bundle is recycled")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.unusedApps, [b],
                       "The recycled app must be dropped from the payload")
        XCTAssertFalse(vm.isRemovingUnusedApps)
    }

    func test_unusedAppDelete_preservesOtherPayload() async {
        // Removing an unused app must not touch installers / unsupported.
        let unused = makeUnused(name: "Dusty", bundleID: "com.dusty.app")
        let installer = makeInstaller(name: "A.dmg", size: 5_000)
        let unsupported = makeUnsupported(name: "Old", bundleID: "com.old.app")
        let vm = makeViewModel(
            discover: { [] },
            installers: { [installer] },
            unsupported: { _ in [unsupported] },
            unused: { _ in [unused] }
        )
        await vm.scan()
        vm.selectAllUnusedApps()

        await vm.deleteSelectedUnusedApps()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertTrue(result.unusedApps.isEmpty)
        XCTAssertEqual(result.installationFiles, [installer])
        XCTAssertEqual(result.unsupportedApps, [unsupported])
    }
}

/// A one-shot async gate so a test can hold an injected closure inside
/// `.scanning` until it chooses to release it. Real concurrency, no mocks.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
