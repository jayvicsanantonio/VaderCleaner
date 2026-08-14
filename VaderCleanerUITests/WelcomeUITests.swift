// WelcomeUITests.swift
// End-to-end walk of the first-run welcome flow: the tour advances and reverses, the tour can be skipped, and finishing hands the user to the main window.

import XCTest

/// Drives the flow through the real app. The launch arguments override the
/// persisted "already seen it" flag through UserDefaults' argument domain, so
/// these tests get a first-run app without the suite having to clear the
/// developer's own preferences.
@MainActor
final class WelcomeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    /// Both first-run flags are forced, not just the flow's: the Scan-disc
    /// hint has its own "already seen" record, so a second run of this suite
    /// would otherwise never see it.
    private func launchAsFirstRun() {
        app.launchArguments = [
            "-welcome.hasCompleted", "NO",
            "-welcome.hasSeenScanHint", "NO",
        ]
        app.launch()
    }

    private func step(_ identifier: String) -> XCUIElement {
        app.groups[identifier].firstMatch
    }

    func test_firstLaunch_opensOnTheWelcomeStep() {
        launchAsFirstRun()
        XCTAssertTrue(
            step("welcome.step.welcome").waitForExistence(timeout: 10),
            "A first run should open on the welcome step"
        )
    }

    func test_returningLaunch_goesStraightToTheApp() {
        app.launchArguments = ["-welcome.hasCompleted", "YES"]
        app.launch()

        XCTAssertTrue(app.otherElements["sidebar.smartScan"].waitForExistence(timeout: 10))
        XCTAssertFalse(step("welcome.step.welcome").exists)
    }

    func test_continue_advancesThroughTheTourAndBackReverses() {
        launchAsFirstRun()
        XCTAssertTrue(step("welcome.step.welcome").waitForExistence(timeout: 10))

        app.buttons["welcome.continue"].click()
        XCTAssertTrue(step("welcome.step.clean").waitForExistence(timeout: 5))

        app.buttons["welcome.continue"].click()
        XCTAssertTrue(step("welcome.step.protect").waitForExistence(timeout: 5))

        app.buttons["welcome.back"].click()
        XCTAssertTrue(step("welcome.step.clean").waitForExistence(timeout: 5))
    }

    func test_skipTour_landsOnTheFullDiskAccessStep() {
        launchAsFirstRun()
        XCTAssertTrue(step("welcome.step.welcome").waitForExistence(timeout: 10))

        app.buttons["welcome.skipTour"].click()
        XCTAssertTrue(step("welcome.step.access").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["welcome.openSystemSettings"].exists)
    }

    func test_relaunchResumesWhereTheFlowLeftOff() {
        // Granting Full Disk Access makes macOS quit the app; the resume point
        // is what carries the user back rather than dropping them at the top
        // of the tour. Forcing the stored step stands in for that restart.
        app.launchArguments = [
            "-welcome.hasCompleted", "NO",
            "-welcome.hasSeenScanHint", "NO",
            // The access step's raw value. A UI test runs out of process and
            // can't import the enum, so this is a literal — but the order it
            // depends on is pinned by
            // `WelcomeStepTests.test_allCases_areInPresentationOrder`, which
            // fails first and loudly if a step is ever inserted ahead of it.
            "-welcome.resumeStep", "5",
        ]
        app.launch()

        XCTAssertTrue(
            step("welcome.step.access").waitForExistence(timeout: 10),
            "A relaunch mid-flow should resume on the step it was interrupted at"
        )
        XCTAssertFalse(step("welcome.step.welcome").exists)
    }

    func test_continue_reachesTheHowItWorksStepAfterTheTour() {
        launchAsFirstRun()
        XCTAssertTrue(step("welcome.step.welcome").waitForExistence(timeout: 10))

        for expected in ["clean", "protect", "tune", "howItWorks"] {
            app.buttons["welcome.continue"].click()
            XCTAssertTrue(
                step("welcome.step.\(expected)").waitForExistence(timeout: 5),
                "Expected to land on the \(expected) step"
            )
        }
    }

    func test_exploreOnMyOwn_pointsTheUserAtTheScanDisc() {
        launchAsFirstRun()
        XCTAssertTrue(step("welcome.step.welcome").waitForExistence(timeout: 10))

        app.buttons["welcome.skipTour"].click()
        XCTAssertTrue(step("welcome.step.access").waitForExistence(timeout: 5))
        app.buttons["welcome.continue"].click()
        XCTAssertTrue(step("welcome.step.ready").waitForExistence(timeout: 5))

        app.buttons["welcome.explore"].click()
        let hint = app.buttons["welcome.scanHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "Explore should leave the Scan hint behind")

        hint.click()
        XCTAssertFalse(hint.waitForExistence(timeout: 3), "Clicking the hint should put it away")
    }

    func test_runFirstSmartScan_skipsTheHint() {
        // The scan is already running and the disc is visibly busy, so the
        // pointer would be narrating something the user can see.
        launchAsFirstRun()
        XCTAssertTrue(step("welcome.step.welcome").waitForExistence(timeout: 10))

        app.buttons["welcome.skipTour"].click()
        XCTAssertTrue(step("welcome.step.access").waitForExistence(timeout: 5))
        app.buttons["welcome.continue"].click()
        XCTAssertTrue(step("welcome.step.ready").waitForExistence(timeout: 5))

        app.buttons["welcome.runFirstScan"].click()
        XCTAssertTrue(app.otherElements["sidebar.smartScan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["welcome.scanHint"].exists)
    }

    func test_finishing_dismissesTheFlowAndRevealsTheApp() {
        launchAsFirstRun()
        XCTAssertTrue(step("welcome.step.welcome").waitForExistence(timeout: 10))

        app.buttons["welcome.skipTour"].click()
        XCTAssertTrue(step("welcome.step.access").waitForExistence(timeout: 5))

        app.buttons["welcome.continue"].click()
        XCTAssertTrue(step("welcome.step.ready").waitForExistence(timeout: 5))

        app.buttons["welcome.explore"].click()
        XCTAssertTrue(app.otherElements["sidebar.smartScan"].waitForExistence(timeout: 10))
        XCTAssertFalse(step("welcome.step.ready").exists)
    }
}
