// WelcomeViewModelTests.swift
// Tests the first-run flow's state machine: step navigation, skipping the tour, live Full Disk Access detection, and how finishing hands off to Smart Scan.

import XCTest
@testable import VaderCleaner

@MainActor
final class WelcomeViewModelTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "VaderCleanerTests.WelcomeViewModel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // See WelcomeStoreTests: NSArgumentDomain outranks an isolated suite,
        // so a scheme passing `-welcome.hasCompleted` would shadow the store
        // this view model is driven by.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSUT(
        store: WelcomeStore? = nil,
        hasFullDiskAccess: @escaping () -> Bool = { false },
        openSystemSettings: @escaping () -> Void = {}
    ) -> WelcomeViewModel {
        WelcomeViewModel(
            store: store ?? WelcomeStore(defaults: defaults),
            fullDiskAccessChecker: hasFullDiskAccess,
            openSystemSettings: openSystemSettings
        )
    }

    // MARK: Presentation

    func test_freshInstall_presentsTheFlowAtTheWelcomeStep() {
        let sut = makeSUT()
        XCTAssertTrue(sut.isPresented)
        XCTAssertEqual(sut.step, .welcome)
    }

    func test_returningUser_neverSeesTheFlow() {
        let store = WelcomeStore(defaults: defaults)
        store.markCompleted()
        XCTAssertFalse(makeSUT(store: store).isPresented)
    }

    // MARK: Navigation

    func test_advance_walksTheStepsInOrder() {
        let sut = makeSUT()
        for expected in WelcomeStep.allCases.dropFirst() {
            sut.advance()
            XCTAssertEqual(sut.step, expected)
        }
    }

    func test_advance_onTheLastStep_holdsRatherThanDismissing() {
        let sut = makeSUT()
        WelcomeStep.allCases.forEach { _ in sut.advance() }
        XCTAssertEqual(sut.step, .ready)
        XCTAssertTrue(sut.isPresented)
    }

    func test_back_walksBackwardAndStopsAtTheFirstStep() {
        let sut = makeSUT()
        sut.advance()
        sut.advance()
        XCTAssertEqual(sut.step, .protect)
        sut.back()
        XCTAssertEqual(sut.step, .clean)
        sut.back()
        sut.back()
        XCTAssertEqual(sut.step, .welcome)
    }

    func test_canGoBack_isFalseOnlyOnTheFirstStep() {
        let sut = makeSUT()
        XCTAssertFalse(sut.canGoBack)
        sut.advance()
        XCTAssertTrue(sut.canGoBack)
    }

    func test_skipTour_jumpsStraightToTheAccessStep() {
        let sut = makeSUT()
        sut.advance()
        sut.skipTour()
        XCTAssertEqual(sut.step, .access)
    }

    func test_skipTour_pastTheTour_leavesTheStepAlone() {
        let sut = makeSUT()
        sut.skipTour()
        sut.advance()
        XCTAssertEqual(sut.step, .ready)
        sut.skipTour()
        XCTAssertEqual(sut.step, .ready)
    }

    func test_canSkipTour_onlyWhileTheTourIsStillAhead() {
        let sut = makeSUT()
        XCTAssertTrue(sut.canSkipTour)
        sut.skipTour()
        XCTAssertFalse(sut.canSkipTour)
    }

    // MARK: Full Disk Access

    func test_accessState_readsTheCheckerUpFront() {
        XCTAssertTrue(makeSUT(hasFullDiskAccess: { true }).hasFullDiskAccess)
        XCTAssertFalse(makeSUT(hasFullDiskAccess: { false }).hasFullDiskAccess)
    }

    func test_refreshAccess_picksUpAccessGrantedWhileTheFlowIsOpen() {
        let granted = TestBox(false)
        let sut = makeSUT(hasFullDiskAccess: { granted.value })
        XCTAssertFalse(sut.hasFullDiskAccess)

        granted.value = true
        sut.refreshAccess()
        XCTAssertTrue(sut.hasFullDiskAccess)
    }

    func test_requestFullDiskAccess_opensSystemSettings() {
        let opened = TestBox(0)
        let sut = makeSUT(openSystemSettings: { opened.value += 1 })
        sut.requestFullDiskAccess()
        XCTAssertEqual(opened.value, 1)
    }

    // MARK: Finishing

    func test_finish_marksTheFlowSeenAndDismissesIt() {
        let store = WelcomeStore(defaults: defaults)
        let sut = makeSUT(store: store)
        sut.finish(startingScan: false)

        XCTAssertFalse(sut.isPresented)
        XCTAssertTrue(store.hasCompletedWelcome)
    }

    func test_finish_reportsWhetherTheUserAskedForTheFirstScan() {
        let requestedScan = TestBox<Bool?>(nil)
        let sut = makeSUT()
        sut.onFinish = { startScan in requestedScan.value = startScan }

        sut.finish(startingScan: true)
        XCTAssertEqual(requestedScan.value, true)
    }

    // MARK: Scan hint

    func test_finish_withoutAScan_pointsTheUserAtTheScanDisc() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isShowingScanHint)
        sut.finish(startingScan: false)
        XCTAssertTrue(sut.isShowingScanHint)
    }

    func test_finish_startingAScan_skipsTheHint() {
        // The scan is already running and the disc is already busy — pointing
        // at it would be telling the user something they can see happening.
        let sut = makeSUT()
        sut.finish(startingScan: true)
        XCTAssertFalse(sut.isShowingScanHint)
    }

    func test_finish_neverRepeatsAHintTheUserHasSeen() {
        let store = WelcomeStore(defaults: defaults)
        store.markScanHintSeen()
        let sut = makeSUT(store: store)
        sut.finish(startingScan: false)
        XCTAssertFalse(sut.isShowingScanHint)
    }

    func test_dismissScanHint_hidesItAndRemembersThat() {
        let store = WelcomeStore(defaults: defaults)
        let sut = makeSUT(store: store)
        sut.finish(startingScan: false)

        sut.dismissScanHint()
        XCTAssertFalse(sut.isShowingScanHint)
        XCTAssertTrue(store.hasSeenScanHint)
    }

    func test_dismissScanHint_whenNothingIsShowing_doesNotBurnTheHint() {
        let store = WelcomeStore(defaults: defaults)
        let sut = makeSUT(store: store)
        sut.dismissScanHint()
        XCTAssertFalse(store.hasSeenScanHint, "A stray dismiss must not spend the one hint the user gets")
    }

    func test_finish_isIdempotent() {
        let calls = TestBox(0)
        let sut = makeSUT()
        sut.onFinish = { _ in calls.value += 1 }

        sut.finish(startingScan: true)
        sut.finish(startingScan: false)
        XCTAssertEqual(calls.value, 1, "A second finish must not re-fire the hand-off")
    }
}
