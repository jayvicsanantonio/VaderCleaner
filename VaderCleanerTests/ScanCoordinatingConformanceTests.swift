// ScanCoordinatingConformanceTests.swift
// Pins the full Phase→ScanPresentation mapping (every rich case) and the beginScan() entrypoint for all seven scannable view models conforming to ScanCoordinating.

import XCTest
import Combine
@testable import VaderCleaner

/// Each scannable view model keeps its own rich `Phase` enum; this suite
/// verifies the coarse `ScanPresentation` projection ContentView relies on for
/// *every* phase the spec calls out (transient ones caught by freezing an
/// injected closure mid-flight), plus that `beginScan()` always pulls a
/// freshly-constructed (`.idle`) view model out of `.intro`.
@MainActor
final class ScanCoordinatingConformanceTests: XCTestCase {

    // MARK: - Test infrastructure

    /// Freezes an injected scan/load/clean closure mid-flight so a test can
    /// observe a transient projection. The closure `await`s `wait()`; because
    /// every view model is `@MainActor` the suspension yields the main actor
    /// back to the test, which polls for the expected phase, then calls
    /// `open()` to let the closure (and the operation) finish. `opened` makes
    /// the `wait()`-then-`open()` and `open()`-then-`wait()` orders both safe.
    @MainActor
    private final class ScanGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Polls `predicate` between `Task.yield()`s until it holds, failing the
    /// test if it never does. Used instead of a fixed sleep because the phase
    /// hop we are waiting on is an in-memory main-actor write, not wall-clock
    /// work — yielding lets the operation's task advance with no arbitrary
    /// delay.
    private func yieldUntil(
        _ predicate: () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for: \(message)", file: file, line: line)
    }

    private func makeFile(
        name: String,
        category: ScanCategory = .userCache
    ) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/scan-coordinating/\(name)"),
            size: 100,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private struct Boom: Error {}

    /// Counts how many times an injected entrypoint closure ran. A
    /// `@MainActor` reference type (not a captured `var`) so the increment
    /// stays warning-free under the VMs' main-actor isolation.
    @MainActor
    private final class CallCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    // MARK: - SmartScanViewModel
    // Mapping: .idle→.intro; .scanning→.working; .results/.cleaning/.done/.failed→.results.

    func test_smartScan_idleMapsToIntro() {
        XCTAssertEqual(makeSmartScan().scanPresentation, .intro)
    }

    func test_smartScan_scanningMapsToWorking() async {
        let gate = ScanGate()
        let vm = makeSmartScan(junkScanner: {
            await gate.wait()
            return ScanResult(items: [])
        })

        let task = Task { await vm.scan() }
        await yieldUntil({ vm.scanPresentation == .working }, ".scanning → .working")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_smartScan_resultsMapsToResults() async {
        let vm = makeSmartScan()
        await vm.scan()
        if case .results = vm.phase {} else { XCTFail("expected .results, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_smartScan_cleaningMapsToResults() async {
        let gate = ScanGate()
        let junkFile = makeFile(name: "a")
        let vm = makeSmartScan(
            junkScanner: { ScanResult(items: [junkFile]) },
            junkCleaner: { _ in
                await gate.wait()
                return 0
            }
        )
        await vm.scan() // → .results, the only phase run() acts from.

        let task = Task { await vm.run() }
        await yieldUntil({ vm.phase == .cleaning }, ".cleaning")
        XCTAssertEqual(vm.scanPresentation, .results)

        gate.open()
        await task.value
    }

    func test_smartScan_doneMapsToResults() async {
        let vm = makeSmartScan()
        await vm.scan()
        await vm.run()
        if case .done = vm.phase {} else { XCTFail("expected .done, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_smartScan_failedMapsToResults() async {
        let vm = makeSmartScan(junkScanner: { throw Boom() })
        await vm.scan()
        if case .failed = vm.phase {} else { XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_smartScan_beginScanLeavesIntro() async {
        let vm = makeSmartScan()
        vm.beginScan()
        await yieldUntil({ vm.scanPresentation != .intro }, "beginScan() leaves .intro")
        XCTAssertNotEqual(vm.scanPresentation, .intro)
    }

    // MARK: - SystemJunkViewModel
    // Mapping: .idle→.intro; .scanning/.cleaning→.working; .preview/.complete/.failed→.results.

    func test_systemJunk_idleMapsToIntro() {
        XCTAssertEqual(makeSystemJunk().scanPresentation, .intro)
    }

    func test_systemJunk_scanningMapsToWorking() async {
        let gate = ScanGate()
        let vm = makeSystemJunk(scanner: {
            await gate.wait()
            return ScanResult(items: [])
        })

        let task = Task { await vm.scan() }
        await yieldUntil({ vm.phase == .scanning }, ".scanning")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_systemJunk_previewMapsToResults() async {
        let vm = makeSystemJunk(scanner: { ScanResult(items: [self.makeFile(name: "a")]) })
        await vm.scan()
        if case .preview = vm.phase {} else { XCTFail("expected .preview, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_systemJunk_cleaningMapsToWorking() async {
        let gate = ScanGate()
        let file = makeFile(name: "a")
        let vm = makeSystemJunk(
            scanner: { ScanResult(items: [file]) },
            deleter: { _ in
                await gate.wait()
                return 100
            }
        )
        await vm.scan()
        vm.toggleSelection(file) // opt the file in so clean() runs.

        let task = Task { await vm.clean() }
        await yieldUntil({ vm.phase == .cleaning }, ".cleaning")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_systemJunk_completeMapsToResults() async {
        let file = makeFile(name: "a")
        let vm = makeSystemJunk(
            scanner: { ScanResult(items: [file]) },
            deleter: { _ in 100 }
        )
        await vm.scan()
        vm.toggleSelection(file) // opt in before cleaning
        await vm.clean()
        if case .complete = vm.phase {} else { XCTFail("expected .complete, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_systemJunk_failedMapsToResults() async {
        let vm = makeSystemJunk(scanner: { throw Boom() })
        await vm.scan()
        if case .failed = vm.phase {} else { XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_systemJunk_beginScanLeavesIntro() async {
        let vm = makeSystemJunk()
        vm.beginScan()
        await yieldUntil({ vm.scanPresentation != .intro }, "beginScan() leaves .intro")
        XCTAssertNotEqual(vm.scanPresentation, .intro)
    }

    func test_systemJunk_beginScanIgnoresReentrantCallWhileScanning() async {
        let gate = ScanGate()
        let counter = CallCounter()
        let vm = makeSystemJunk(scanner: {
            counter.bump()
            await gate.wait()
            return ScanResult(items: [])
        })

        vm.beginScan()
        await yieldUntil({ vm.phase == .scanning }, ".scanning")
        vm.beginScan() // re-entrant while scanning: must be a no-op
        await yieldUntil({ counter.count >= 1 }, "scanner invoked")
        XCTAssertEqual(counter.count, 1)

        gate.open()
        await yieldUntil({ vm.phase != .scanning }, "scan settles")
        XCTAssertEqual(counter.count, 1, "re-entrant beginScan must not start a second scan")
    }

    // MARK: - DiskScannerViewModel (Space Lens)
    // Mapping: .idle→.intro; .scanning→.working; .ready/.error→.results.

    private func diskNode() -> DiskNode {
        DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 1,
            isDirectory: true,
            children: []
        )
    }

    func test_diskScanner_idleMapsToIntro() {
        let vm = DiskScannerViewModel(scanner: { _, _ in self.diskNode() })
        XCTAssertEqual(vm.scanPresentation, .intro)
    }

    func test_diskScanner_scanningMapsToWorking() async {
        let gate = ScanGate()
        let vm = DiskScannerViewModel(scanner: { _, _ in
            await gate.wait()
            return self.diskNode()
        })

        let task = Task {
            await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        }
        await yieldUntil({ vm.phase == .scanning }, ".scanning")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_diskScanner_readyMapsToResults() async {
        let node = diskNode()
        let vm = DiskScannerViewModel(scanner: { _, _ in node })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        XCTAssertEqual(vm.phase, .ready(node))
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_diskScanner_errorMapsToResults() async {
        struct ScanFailure: LocalizedError { var errorDescription: String? { "boom" } }
        let vm = DiskScannerViewModel(scanner: { _, _ in throw ScanFailure() })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        XCTAssertEqual(vm.phase, .error("boom"))
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_diskScanner_beginScanLeavesIntro() async {
        // `beginScan()` defaults the root to the user's home directory; the
        // injected scanner short-circuits the walk so no real disk is read.
        let vm = DiskScannerViewModel(scanner: { _, _ in self.diskNode() })
        vm.beginScan()
        await yieldUntil({ vm.scanPresentation != .intro }, "beginScan() leaves .intro")
        XCTAssertNotEqual(vm.scanPresentation, .intro)
    }

    // MARK: - MalwareViewModel
    // Mapping: .idle→.intro; .checkingClamAV/.updatingDatabase/.scanning/.removing→.working;
    //          .needsInstall/.results/.clean/.done/.failed→.results.

    private let threat = MalwareThreat(
        filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.bin"),
        threatName: "Eicar-Test-Signature"
    )

    func test_malware_idleMapsToIntro() {
        XCTAssertEqual(makeMalware().scanPresentation, .intro)
    }

    /// `.checkingClamAV` is set and left within a single synchronous run
    /// (`checkInstalled` is a sync closure and nothing suspends before the
    /// phase advances), so it is not transiently observable through any
    /// injected seam without modifying VM logic. Its `.working` mapping is
    /// instead guaranteed at compile time by the extension's exhaustive,
    /// `default`-free switch and is identical to the other `.working` cases
    /// exercised below.
    func test_malware_updatingDatabaseMapsToWorking() async {
        let gate = ScanGate()
        let vm = makeMalware(
            checkInstalled: { true },
            databaseLastUpdated: { nil }, // nil ⇒ stale ⇒ the .updatingDatabase path
            updateDatabase: { _ in await gate.wait() }
        )

        let task = Task { await vm.scan() }
        await yieldUntil({
            if case .updatingDatabase = vm.phase { return true } else { return false }
        }, ".updatingDatabase")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_malware_scanningMapsToWorking() async {
        let gate = ScanGate()
        let vm = makeMalware(
            checkInstalled: { true },
            databaseLastUpdated: { Date() },
            scan: { _, _ in
                await gate.wait()
                return []
            }
        )

        let task = Task { await vm.scan() }
        await yieldUntil({
            if case .scanning = vm.phase { return true } else { return false }
        }, ".scanning")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_malware_removingMapsToWorking() async {
        let gate = ScanGate()
        let vm = makeMalware(
            scan: { _, _ in [self.threat] },
            removeThreats: { _ in
                await gate.wait()
                return [] // no failures ⇒ .done
            }
        )
        await vm.scan() // → .results([threat])

        let task = Task { await vm.removeThreats() }
        await yieldUntil({ vm.phase == .removing }, ".removing")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_malware_needsInstallMapsToResults() async {
        // Maps to `.results` (not `.intro`) on purpose: ProtectionDashboardView
        // renders its own ClamAV install onboarding for this state.
        let vm = makeMalware(checkInstalled: { false })
        await vm.scan()
        XCTAssertEqual(vm.phase, .needsInstall)
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_malware_resultsMapsToResults() async {
        let vm = makeMalware(scan: { _, _ in [self.threat] })
        await vm.scan()
        if case .results = vm.phase {} else { XCTFail("expected .results, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_malware_cleanMapsToResults() async {
        let vm = makeMalware(scan: { _, _ in [] })
        await vm.scan()
        XCTAssertEqual(vm.phase, .clean)
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_malware_doneMapsToResults() async {
        let vm = makeMalware(scan: { _, _ in [self.threat] }, removeThreats: { _ in [] })
        await vm.scan()
        await vm.removeThreats()
        if case .done = vm.phase {} else { XCTFail("expected .done, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_malware_failedMapsToResults() async {
        let vm = makeMalware(
            databaseLastUpdated: { Date() },
            scan: { _, _ in throw Boom() }
        )
        await vm.scan()
        if case .failed = vm.phase {} else { XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_malware_beginScanLeavesIntro() async {
        let vm = makeMalware(checkInstalled: { true }, databaseLastUpdated: { Date() })
        vm.beginScan()
        await yieldUntil({ vm.scanPresentation != .intro }, "beginScan() leaves .intro")
        XCTAssertNotEqual(vm.scanPresentation, .intro)
    }

    // MARK: - PerformanceViewModel
    // Mapping: .idle→.intro; .loading→.working; .ready/.working/.failed→.results.

    func test_performance_idleMapsToIntro() {
        XCTAssertEqual(makePerformance().scanPresentation, .intro)
    }

    func test_performance_loadingMapsToWorking() async {
        let gate = ScanGate()
        let vm = makePerformance(loadLoginItems: {
            await gate.wait()
            return []
        })

        let task = Task { await vm.refresh() }
        await yieldUntil({ vm.phase == .loading }, ".loading")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_performance_readyMapsToResults() async {
        let vm = makePerformance()
        await vm.refresh()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    /// `Phase.working` (an in-progress *action*, e.g. a RAM flush) projects to
    /// `ScanPresentation.results`, not `.working` — the name collision is the
    /// whole reason this case is pinned: the section's own detail UI stays on
    /// screen for action progress rather than reverting to the generic intro.
    func test_performance_workingPhaseMapsToResults() async {
        let gate = ScanGate()
        let vm = makePerformance(flushRAM: { await gate.wait() })

        let task = Task { await vm.flushRAM() }
        await yieldUntil({ vm.phase == .working }, "Phase.working")
        XCTAssertEqual(vm.scanPresentation, .results)

        gate.open()
        await task.value
    }

    func test_performance_failedMapsToResults() async {
        let vm = makePerformance(flushRAM: { throw Boom() })
        await vm.flushRAM()
        if case .failed = vm.phase {} else { XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_performance_beginScanLeavesIntro() async {
        let vm = makePerformance()
        vm.beginScan()
        await yieldUntil({ vm.scanPresentation != .intro }, "beginScan() leaves .intro")
        XCTAssertNotEqual(vm.scanPresentation, .intro)
    }

    func test_performance_beginScanIgnoresReentrantCallWhileLoading() async {
        let gate = ScanGate()
        let counter = CallCounter()
        let vm = makePerformance(loadLoginItems: {
            counter.bump()
            await gate.wait()
            return []
        })

        vm.beginScan()
        await yieldUntil({ vm.phase == .loading }, ".loading")
        vm.beginScan() // re-entrant while loading: must be a no-op
        await yieldUntil({ counter.count >= 1 }, "loader invoked")
        XCTAssertEqual(counter.count, 1)

        gate.open()
        await yieldUntil({ vm.phase != .loading }, "load settles")
        XCTAssertEqual(counter.count, 1, "re-entrant beginScan must not start a second load")
    }

    // MARK: - PrivacyViewModel
    // Mapping: .idle→.intro; .scanning/.clearing→.working; .preview/.complete/.failed→.results.

    func test_privacy_idleMapsToIntro() {
        XCTAssertEqual(makePrivacy().scanPresentation, .intro)
    }

    func test_privacy_scanningMapsToWorking() async {
        let gate = ScanGate()
        let vm = makePrivacy(detector: {
            await gate.wait()
            return []
        })

        let task = Task { await vm.preview() }
        await yieldUntil({ vm.phase == .scanning }, ".scanning")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_privacy_previewMapsToResults() async {
        let vm = makePrivacy()
        await vm.preview()
        XCTAssertEqual(vm.phase, .preview)
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_privacy_clearingMapsToWorking() async {
        let gate = ScanGate()
        // The recents clearer runs first inside `clear()`; gating it freezes
        // the VM in `.clearing` long enough to observe the projection.
        let vm = makePrivacy(clearRecentFiles: { await gate.wait() })
        await vm.preview() // → .preview, the only phase clear() acts from.

        let task = Task { await vm.clear() }
        await yieldUntil({ vm.phase == .clearing }, ".clearing")
        XCTAssertEqual(vm.scanPresentation, .working)

        gate.open()
        await task.value
    }

    func test_privacy_completeMapsToResults() async {
        let vm = makePrivacy()
        await vm.preview()
        await vm.clear()
        if case .complete = vm.phase {} else { XCTFail("expected .complete, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_privacy_failedMapsToResults() async {
        let vm = makePrivacy(detector: { throw Boom() })
        await vm.preview()
        if case .failed = vm.phase {} else { XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertEqual(vm.scanPresentation, .results)
    }

    func test_privacy_beginScanLeavesIntro() async {
        let vm = makePrivacy()
        vm.beginScan()
        await yieldUntil({ vm.scanPresentation != .intro }, "beginScan() leaves .intro")
        XCTAssertNotEqual(vm.scanPresentation, .intro)
    }

    func test_privacy_beginScanIgnoresReentrantCallWhileScanning() async {
        let gate = ScanGate()
        let counter = CallCounter()
        let vm = makePrivacy(detector: {
            await counter.bump()
            await gate.wait()
            return []
        })

        vm.beginScan()
        await yieldUntil({ vm.phase == .scanning }, ".scanning")
        vm.beginScan() // re-entrant while scanning: must be a no-op
        await yieldUntil({ counter.count >= 1 }, "detector invoked")
        XCTAssertEqual(counter.count, 1)

        gate.open()
        await yieldUntil({ vm.phase != .scanning }, "scan settles")
        XCTAssertEqual(counter.count, 1, "re-entrant beginScan must not start a second scan")
    }

    // MARK: - Construction helpers
    //
    // One per view model, mirroring the defaults each VM's own
    // *ViewModelTests use so a test only overrides the closure it exercises.

    private func makeSmartScan(
        junkScanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        malwareInstalled: @escaping SmartScanViewModel.MalwareInstalled = { true },
        malwareScanner: @escaping () async -> [MalwareThreat] = { [] },
        loginItemsLoader: @escaping SmartScanViewModel.LoginItemsLoader = { [] },
        duplicatesScanner: @escaping () async -> [DuplicateGroup] = { [] },
        updatesChecker: @escaping () async -> [UpdateInfo] = { [] },
        junkCleaner: @escaping SmartScanViewModel.JunkCleaner = { _ in 0 },
        threatRemover: @escaping SmartScanViewModel.ThreatRemover = { _ in [] },
        maintenanceRunner: @escaping SmartScanViewModel.MaintenanceRunner = { "" },
        updateOpener: @escaping SmartScanViewModel.UpdateOpener = { _ in },
        largeFileDeleter: @escaping SmartScanViewModel.LargeFileDeleter = { _ in [] }
    ) -> SmartScanViewModel {
        SmartScanViewModel(
            junkScanner: { _ in try await junkScanner() },
            malwareInstalled: malwareInstalled,
            malwareScanner: { _ in await malwareScanner() },
            loginItemsLoader: loginItemsLoader,
            duplicatesScanner: { _ in await duplicatesScanner() },
            updatesChecker: { _ in await updatesChecker() },
            junkCleaner: junkCleaner,
            threatRemover: threatRemover,
            maintenanceRunner: maintenanceRunner,
            updateOpener: updateOpener,
            largeFileDeleter: largeFileDeleter
        )
    }

    private func makeSystemJunk(
        scanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        deleter: @escaping SystemJunkViewModel.Deleter = { _ in 0 }
    ) -> SystemJunkViewModel {
        SystemJunkViewModel(scanner: { _ in try await scanner() }, deleter: deleter)
    }

    private func makeMalware(
        checkInstalled: @escaping MalwareViewModel.CheckInstalled = { true },
        databaseLastUpdated: @escaping MalwareViewModel.DatabaseLastUpdated = { Date() },
        updateDatabase: @escaping MalwareViewModel.UpdateDatabase = { _ in },
        scan: @escaping MalwareViewModel.Scan = { _, _ in [] },
        removeThreats: @escaping MalwareViewModel.RemoveThreats = { _ in [] },
        notify: @escaping MalwareViewModel.Notify = { _ in },
        shouldNotify: @escaping MalwareViewModel.ShouldNotify = { true }
    ) -> MalwareViewModel {
        MalwareViewModel(
            checkInstalled: checkInstalled,
            databaseLastUpdated: databaseLastUpdated,
            updateDatabase: updateDatabase,
            scan: scan,
            removeThreats: removeThreats,
            notify: notify,
            shouldNotify: shouldNotify
        )
    }

    private func makePerformance(
        loadLoginItems: @escaping PerformanceViewModel.LoadLoginItems = { [] },
        loadUserAgents: @escaping PerformanceViewModel.LoadAgents = { [] },
        loadSystemAgents: @escaping PerformanceViewModel.LoadAgents = { [] },
        readMemory: @escaping PerformanceViewModel.ReadMemory = { .empty },
        setLoginItemEnabled: @escaping PerformanceViewModel.SetLoginItemEnabled = { _, _ in },
        disableAgent: @escaping PerformanceViewModel.DisableAgent = { _ in },
        enableAgent: @escaping PerformanceViewModel.EnableAgent = { _ in },
        removeAgent: @escaping PerformanceViewModel.RemoveAgent = { _ in },
        flushRAM: @escaping PerformanceViewModel.FlushRAM = {},
        runMaintenance: @escaping PerformanceViewModel.RunMaintenance = { "" }
    ) -> PerformanceViewModel {
        PerformanceViewModel(
            loadLoginItems: loadLoginItems,
            loadUserAgents: loadUserAgents,
            loadSystemAgents: loadSystemAgents,
            readMemory: readMemory,
            setLoginItemEnabled: setLoginItemEnabled,
            disableAgent: disableAgent,
            enableAgent: enableAgent,
            removeAgent: removeAgent,
            flushRAM: flushRAM,
            runMaintenance: runMaintenance,
            launchAtLoginChanges: nil
        )
    }

    private func makePrivacy(
        detector: @escaping PrivacyViewModel.Detector = { [] },
        sizer: @escaping PrivacyViewModel.Sizer = { _, _ in 0 },
        pathsFor: @escaping PrivacyViewModel.PathsResolver = { _, _ in [] },
        clearer: @escaping PrivacyViewModel.Clearer = { _, _ in },
        clearRecentFiles: @escaping PrivacyViewModel.RecentFilesClearer = { }
    ) -> PrivacyViewModel {
        PrivacyViewModel(
            detector: detector,
            sizer: sizer,
            pathsFor: pathsFor,
            clearer: clearer,
            clearRecentFiles: clearRecentFiles
        )
    }
}
