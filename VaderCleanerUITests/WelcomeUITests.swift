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

    private func launchAsFirstRun() {
        app.launchArguments = ["-welcome.hasCompleted", "NO"]
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
