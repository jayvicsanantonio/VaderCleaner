// SmartScanViewModelFinishRunTests.swift
// Tests what Done does after a Run: the feed comes back with untouched findings intact, only the units the run handled are re-scanned, and history isn't stamped a second time.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelFinishRunTests: XCTestCase {

    // MARK: - Fixtures

    private nonisolated static func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private nonisolated static func plan(
        findings: [CareFinding],
        outcomes: [CareScanUnit: CareUnitOutcome]
    ) -> CarePlan {
        CarePlan(
            findings: findings,
            health: nil,
            unitOutcomes: outcomes,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
    }

    private nonisolated static var untouchedLargeFile: CareFinding {
        CareFinding(kind: .largeOldFiles, payload: .largeOldFiles([file("/Movies/huge.mov", size: 9_000, category: .largeFile)]))
    }

    /// Junk (pre-approved, so Run handles it) plus an opt-in large-file finding
    /// the run never touches — the pair the refresh has to treat differently.
    private nonisolated static var scanned: CarePlan {
        plan(
            findings: [
                CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [file("/cache/safe", size: 1_000)]))),
                untouchedLargeFile,
            ],
            outcomes: [.systemJunk: .completed, .largeOldFiles: .completed, .malware: .completed]
        )
    }

    /// What the targeted re-scan finds: the junk is gone.
    private nonisolated static var rescanned: CarePlan {
        plan(findings: [], outcomes: [.systemJunk: .completed])
    }

    /// Drives scan → run → Done against an engine that answers `scanned` first
    /// and `rescanned` after, recording every configuration it was handed.
    ///
    /// `duringRefresh` runs on the main actor inside the second engine call — the
    /// window while the re-check is in flight, which is where the interesting
    /// state lives (what the feed is showing, whether Fix is reachable).
    private func viewModel(
        configurations: TestBox<[CareScanEngine.Configuration]> = TestBox([]),
        scanCount: TestBox<Int> = TestBox(0),
        recordScan: @escaping @Sendable (Date) -> Void = { _ in },
        duringRefresh: (@MainActor @Sendable (SmartScanViewModel) -> Void)? = nil
    ) -> SmartScanViewModel {
        let box = TestBox<SmartScanViewModel?>(nil)
        let vm = SmartScanViewModel(
            scanEngine: { configuration, _ in
                configurations.value.append(configuration)
                scanCount.value += 1
                if scanCount.value == 2, let duringRefresh {
                    await MainActor.run {
                        if let vm = box.value { duringRefresh(vm) }
                    }
                }
                return scanCount.value == 1 ? Self.scanned : Self.rescanned
            },
            junkCleaner: { files in files.reduce(0) { $0 + $1.size } },
            recordScan: recordScan
        )
        box.value = vm
        return vm
    }

    // MARK: - Returning to the feed

    func test_finishRun_returnsToTheFeedInsteadOfTheIntro() async {
        let vm = viewModel()

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        guard case .results = vm.phase else {
            return XCTFail("expected .results, got \(vm.phase)")
        }
    }

    /// The whole point of Done: the feed is already back while the re-check
    /// runs. A scanning screen here is what made Done feel like a second scan.
    func test_finishRun_landsOnTheFeedBeforeTheRecheckFinishes() async {
        let phaseDuringRefresh = TestBox<String?>(nil)
        let vm = viewModel(duringRefresh: { phaseDuringRefresh.value = $0.phaseID })

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(phaseDuringRefresh.value, "results", "Done must not show a scanning screen")
    }

    func test_finishRun_takesTheCleanedCardOffTheFeedWhileItRechecks() async {
        let junkDuringRefresh = TestBox<CareFinding??>(nil)
        let largeDuringRefresh = TestBox<CareFinding??>(nil)
        let vm = viewModel(duringRefresh: {
            junkDuringRefresh.value = $0.currentPlan?.finding(.junkCleanup)
            largeDuringRefresh.value = $0.currentPlan?.finding(.largeOldFiles)
        })

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(junkDuringRefresh.value, .some(nil), "a card describing deleted files must go at once")
        XCTAssertEqual(largeDuringRefresh.value, Self.untouchedLargeFile, "an untouched card stays put")
    }

    /// Fix would act on a plan that is missing whatever is being re-checked, so
    /// the disc waits until the plan is whole again.
    func test_finishRun_holdsTheRunDiscUntilTheRecheckLands() async {
        let discDuringRefresh = TestBox<Bool?>(nil)
        let refreshingDuringRefresh = TestBox<Bool?>(nil)
        let vm = viewModel(duringRefresh: {
            discDuringRefresh.value = $0.isRunDiscVisible
            refreshingDuringRefresh.value = $0.isRefreshingFindings
        })

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(refreshingDuringRefresh.value, true)
        XCTAssertEqual(discDuringRefresh.value, false)
        XCTAssertFalse(vm.isRefreshingFindings, "the flag clears once the plan is whole")
    }

    /// Selections outlive the plan they came from, so the totals in the zone
    /// footers and the disc caption would keep counting deleted files.
    func test_finishRun_clearsTheSelectionOfWhatItCleaned() async {
        let selectedBytesDuringRefresh = TestBox<Int64?>(nil)
        let vm = viewModel(duringRefresh: { selectedBytesDuringRefresh.value = $0.selectedJunkBytes })

        await vm.scan()
        XCTAssertGreaterThan(vm.selectedJunkBytes, 0, "the scan seeds a junk selection to clean")
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(selectedBytesDuringRefresh.value, 0)
    }

    func test_finishRun_keepsFindingsTheRunNeverTouched() async {
        let vm = viewModel()

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(
            vm.currentPlan?.finding(.largeOldFiles), Self.untouchedLargeFile,
            "an opt-in finding the run left alone must survive Done"
        )
    }

    func test_finishRun_dropsWhatTheRunCleaned() async {
        let vm = viewModel()

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertNil(vm.currentPlan?.finding(.junkCleanup), "the cleaned junk is gone and must not linger")
    }

    // MARK: - Scope of the re-scan

    func test_finishRun_rescansOnlyTheUnitsWhoseWorkLanded() async {
        let configurations = TestBox<[CareScanEngine.Configuration]>([])
        let vm = viewModel(configurations: configurations)

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(configurations.value.count, 2, "Done re-scans rather than reusing stale data")
        XCTAssertEqual(
            configurations.value.last?.enabledUnits, [.systemJunk, .healthSnapshot],
            "only the unit the run acted on is re-checked; health rides along for the freed-space number"
        )
    }

    /// The expensive lanes are exactly what a full re-scan made the user pay for.
    func test_finishRun_doesNotRescanUnitsTheRunNeverTouched() async {
        let configurations = TestBox<[CareScanEngine.Configuration]>([])
        let vm = viewModel(configurations: configurations)

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        let units = configurations.value.last?.enabledUnits ?? []
        XCTAssertFalse(units.contains(.malware))
        XCTAssertFalse(units.contains(.duplicates))
        XCTAssertFalse(units.contains(.largeOldFiles))
    }

    func test_finishRun_withNothingDone_showsTheFeedWithoutRescanning() async {
        let scanCount = TestBox(0)
        let vm = viewModel(scanCount: scanCount)

        await vm.scan()
        // Exclude the one pre-approved card, so the pass has nothing to do.
        vm.setFindingIncluded(.junkCleanup, false)
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(scanCount.value, 1, "a run that changed nothing has nothing to re-check")
        XCTAssertEqual(vm.currentPlan, Self.scanned, "the plan comes back untouched")
    }

    /// A tune-up the helper refused, a threat that couldn't be quarantined: the
    /// action failed, so nothing on disk moved and the finding is still true.
    /// Re-scanning it would be work for an answer we already have.
    func test_finishRun_keepsAFindingWhoseActionChangedNothing() async {
        let scanCount = TestBox(0)
        let due = CareFinding(kind: .maintenanceDue, payload: .maintenanceDue(taskIDs: ["flushDNS"]))
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in
                scanCount.value += 1
                return Self.plan(findings: [due], outcomes: [.maintenanceDue: .completed])
            },
            maintenanceTaskRunner: { _ in throw NSError(domain: NSCocoaErrorDomain, code: 4099) }
        )

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(scanCount.value, 1, "a failed action left nothing to re-check")
        XCTAssertEqual(vm.currentPlan?.finding(.maintenanceDue), due, "the tune-up is still due and still shown")
    }

    // MARK: - History and hand-off

    /// A targeted refresh is not a new scan: stamping it would date the user's
    /// scan history from a partial re-check.
    func test_finishRun_doesNotStampANewScanDate() async {
        let stamps = TestBox(0)
        let vm = viewModel(recordScan: { _ in stamps.value += 1 })

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(stamps.value, 1, "only the scan itself stamps history")
    }

    /// The other sections prewarm off the completed plan, so they need the
    /// post-cleanup one too — otherwise they show files that no longer exist.
    func test_finishRun_handsTheMergedPlanToTheOtherSections() async {
        let plans = TestBox<[CarePlan]>([])
        let vm = viewModel()
        vm.onScanCompleted = { plans.value.append($0) }

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        XCTAssertEqual(plans.value.count, 2)
        XCTAssertNil(plans.value.last?.finding(.junkCleanup))
        XCTAssertEqual(plans.value.last?.finding(.largeOldFiles), Self.untouchedLargeFile)
    }

    // MARK: - Fallback

    /// Called from any phase but `.done`, Done still has to leave a sane state
    /// rather than kicking off a re-scan of nothing.
    func test_rescanHandledFindings_outsideDone_isANoOp() async {
        let scanCount = TestBox(0)
        let vm = viewModel(scanCount: scanCount)

        await vm.scan()
        await vm.rescanHandledFindings()

        XCTAssertEqual(scanCount.value, 1)
        XCTAssertEqual(vm.currentPlan, Self.scanned)
    }
}
