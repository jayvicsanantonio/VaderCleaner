// PerformanceUITests.swift
// End-to-end UI test for Performance — navigates to the section, taps the floating Scan on the unified intro, and asserts the view renders (a ready-state section + its in-content Refresh control) so the sidebar → view-model → view wiring is exercised against the real app process.

import XCTest

/// We do not exercise the destructive controls (Disable / Remove / Free Up
/// RAM / Run Maintenance Scripts) here — those would mutate launchd state or
/// run privileged scripts on the test machine. The action contracts are
/// covered exhaustively by `PerformanceViewModelTests` and the manager unit
/// tests against injected fakes. This test only proves the section renders
/// without crashing, which the unit tests cannot.
final class PerformanceUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func test_navigateToPerformance_scan_revealsDashboardAndCatalog() throws {
        dismissOnboardingIfNeeded()

        let sidebarRow = app.buttons["sidebar.performance"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected Performance row in sidebar")
        sidebarRow.click()

        // Performance lands on the unified intro first; tapping the floating
        // Scan kicks off the load that previously ran automatically on appear.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for Performance")
        // The per-section identifier proves it is *Performance's* intro, not
        // merely "an intro" — the "right title" contract.
        let performanceIntro = app.descendants(matching: .any)["section.intro.performance"]
        XCTAssertTrue(performanceIntro.waitForExistence(timeout: 5),
                      "Expected the Performance-specific intro identifier")
        let floatingScan = app.buttons["section.performance.scan"]
        XCTAssertTrue(floatingScan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Performance intro")
        floatingScan.click()

        // Landing on the ready state surfaces the recommendation dashboard.
        // Generous timeout because discovery shells out to `launchctl list`.
        // "View All Tasks" is always present on the dashboard (even when there
        // are no recommendations), so it is the stable "section rendered" signal.
        let viewAllTasks = app.buttons["performance.viewAllTasks"]
        XCTAssertTrue(viewAllTasks.waitForExistence(timeout: 30),
                      "Expected the Performance dashboard to reach its ready state")

        // Opening "View All Tasks" reveals the Performance Manager with the
        // maintenance tasks — proves the dashboard → manager swap wiring works.
        viewAllTasks.click()
        let catalog = app.descendants(matching: .any)["performance.catalog"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5),
                      "Expected the task catalog after tapping View All Tasks")
        let flushDNSRow = app.descendants(matching: .any)["performance.task.flushDNS"]
        XCTAssertTrue(flushDNSRow.waitForExistence(timeout: 5),
                      "Expected the Flush DNS task row in the catalog")
    }

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }
}
