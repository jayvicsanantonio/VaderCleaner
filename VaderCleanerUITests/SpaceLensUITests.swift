// SpaceLensUITests.swift
// End-to-end UI test for Space Lens — navigates to the section, taps the floating Scan on the unified intro, and waits for either the in-progress scan or the post-scan treemap, asserting that the wiring between sidebar selection, view-model, and view reaches the user's home directory.

import XCTest

/// We do not assert on individual treemap tiles here. The home directory
/// scanned by the test machine is whatever the CI / developer runner
/// happens to have, so the only stable invariant is that the section
/// loads and the scan reaches a recognizable state. Tile rendering is
/// covered by `TreemapLayoutTests` against synthetic fixtures.
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

    /// Sidebar → Space Lens must reach either the in-progress scanning
    /// indicator or the loaded treemap (or, on a permission-denied home
    /// directory, the error banner). Any of these is evidence that the
    /// view-model is alive and the scan kicked off — anything else is a
    /// wiring regression.
    func test_navigateToSpaceLens_scan_revealsScanningOrTreemap() throws {
        dismissOnboardingIfNeeded()

        let sidebarRow = app.buttons["sidebar.spaceLens"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected Space Lens row in sidebar")
        sidebarRow.click()

        // Space Lens lands on the unified intro first; tapping the floating
        // Scan kicks off the walk that previously ran automatically on appear.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for Space Lens")
        let floatingScan = app.buttons["section.spaceLens.scan"]
        XCTAssertTrue(floatingScan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Space Lens intro")
        floatingScan.click()

        // After Scan we expect either the scanning indicator or — on tiny home
        // folders / fast machines — the treemap to land before our timeout.
        // The error banner is accepted as well: a CI runner without
        // home-folder access should still surface a recognizable state, not
        // hang on a blank canvas.
        let appeared = waitForAnySpaceLensState(timeout: 30)
        XCTAssertTrue(appeared,
                      "Expected to land on a recognizable Space Lens state after selection")
    }

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    private func waitForAnySpaceLensState(timeout: TimeInterval) -> Bool {
        let identifiers = [
            "space-lens.scanning",
            "space-lens.treemap",
            "space-lens.error",
            "space-lens.empty"
        ]
        let predicate = NSPredicate(format: "identifier IN %@", identifiers)
        return app.groups.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
