// SpaceLensUITests.swift
// End-to-end UI test for Space Lens — navigates to the section, taps the floating Scan on the unified intro, and waits for either the in-progress scan or the loaded bubble explorer, asserting the sidebar → view-model → view wiring reaches a recognizable state.

import XCTest

/// We don't assert on individual bubbles or rows — the boot volume scanned by
/// the test machine is whatever the CI / developer runner happens to have, so
/// the only stable invariant is that the section loads and the scan reaches a
/// recognizable state. Layout and selection logic are covered by the unit suites
/// (`SpaceLensBubbleLayoutTests`, `SpaceLensSelectionTests`, …).
final class SpaceLensUITests: XCTestCase {

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

    /// Sidebar → Space Lens → Scan must reach either the in-progress scanning
    /// indicator, the loaded bubble explorer, the empty placeholder, or the
    /// error banner. Any of these proves the view-model is alive and the scan
    /// kicked off — anything else is a wiring regression.
    func test_navigateToSpaceLens_scan_revealsScanningOrExplorer() throws {
        dismissOnboardingIfNeeded()
        navigateToSpaceLensAndScan()

        let appeared = waitForAnySpaceLensState(timeout: 30)
        XCTAssertTrue(appeared,
                      "Expected to land on a recognizable Space Lens state after selection")
    }

    /// If the scan reaches the ready state, the explorer's chrome must be wired:
    /// the left list panel and the (disabled-until-selection) Review and Remove
    /// button. Whole-volume scans are slow and need Full Disk Access, so a host
    /// that never reaches ready skips rather than fails.
    func test_readyState_showsListAndReviewControls() throws {
        dismissOnboardingIfNeeded()
        navigateToSpaceLensAndScan()

        let list = app.groups["space-lens.list"]
        guard list.waitForExistence(timeout: 60) else {
            throw XCTSkip("Space Lens did not reach the ready state on this host; the explorer chrome only appears once results render.")
        }
        XCTAssertTrue(app.buttons["space-lens.reviewAndRemove"].exists,
                      "The Review and Remove button should be present in the ready state")
        XCTAssertTrue(app.buttons["space-lens.startOver"].exists,
                      "The Start Over control should be present in the ready state")
    }

    // MARK: - Helpers

    private func navigateToSpaceLensAndScan() {
        let sidebarRow = app.buttons["sidebar.spaceLens"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected Space Lens row in sidebar")
        sidebarRow.click()

        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for Space Lens")
        let spaceLensIntro = app.descendants(matching: .any)["section.intro.spacelens"]
        XCTAssertTrue(spaceLensIntro.waitForExistence(timeout: 5),
                      "Expected the Space Lens-specific intro identifier")
        let floatingScan = app.buttons["section.spaceLens.scan"]
        XCTAssertTrue(floatingScan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Space Lens intro")
        floatingScan.click()
        proceedPastScanAccessPopoverIfNeeded()
    }

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    /// The floating Scan button gates FDA-sensitive sections behind an access
    /// popover when Full Disk Access is missing. Tap "Scan Anyway" so the scan
    /// proceeds and the wiring under test still runs.
    private func proceedPastScanAccessPopoverIfNeeded() {
        let scanAnyway = app.buttons["fda.popover.scanAnyway"]
        if scanAnyway.waitForExistence(timeout: 5) {
            scanAnyway.click()
        }
    }

    private func waitForAnySpaceLensState(timeout: TimeInterval) -> Bool {
        let groupIDs = ["space-lens.scanning", "space-lens.bubbles", "space-lens.error", "space-lens.empty", "space-lens.list"]
        let predicate = NSPredicate(format: "identifier IN %@", groupIDs)
        return app.groups.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
