// OptimizationUITests.swift
// End-to-end UI test for Optimization — navigates to the section and asserts the view renders (toolbar + a ready-state section) so the sidebar → view-model → view wiring is exercised against the real app process.

import XCTest

/// We do not exercise the destructive controls (Disable / Remove / Free Up
/// RAM / Run Maintenance Scripts) here — those would mutate launchd state or
/// run privileged scripts on the test machine. The action contracts are
/// covered exhaustively by `OptimizationViewModelTests` and the manager unit
/// tests against injected fakes. This test only proves the section renders
/// without crashing, which the unit tests cannot.
final class OptimizationUITests: XCTestCase {

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

    func test_navigateToOptimization_revealsToolbarAndContent() throws {
        dismissOnboardingIfNeeded()

        let sidebarRow = app.outlines.staticTexts["Optimization"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected Optimization row in sidebar")
        sidebarRow.click()

        // The refresh toolbar button is present whenever the view renders,
        // independent of phase — strongest "view did not crash" signal.
        let refresh = app.buttons["optimization.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10),
                      "Expected Optimization toolbar to render")

        // Loading runs automatically on first appearance; landing on the
        // ready state surfaces the RAM usage label. Generous timeout because
        // discovery shells out to `launchctl list`.
        let ramUsage = app.staticTexts["optimization.ramUsage"]
        XCTAssertTrue(ramUsage.waitForExistence(timeout: 30),
                      "Expected Optimization to reach its ready state")
    }

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }
}
