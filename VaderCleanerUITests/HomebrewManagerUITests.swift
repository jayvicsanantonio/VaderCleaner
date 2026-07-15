// HomebrewManagerUITests.swift
// End-to-end coverage for the Homebrew Manager — Applications → Manage Homebrew opens the surface and Back returns — exercised against the real app process and the host's real Homebrew.

import XCTest

/// Drives display states only; never presses upgrade, uninstall, or cleanup.
/// The mutating side-effects are covered by HomebrewViewModel unit tests.
final class HomebrewManagerUITests: XCTestCase {

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

    /// The Uninstaller pane's Homebrew facet (under the Stores group) swaps the
    /// list to the Homebrew packages, reaching a valid display state; Back
    /// returns to the dashboard.
    func test_applications_uninstallerHomebrewFacetShowsPackages() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90),
                      "Expected the Manage My Applications button after the scan")
        manage.click()

        XCTAssertTrue(app.descendants(matching: .any)["applications.manager"].waitForExistence(timeout: 10),
                      "Expected the Applications Manager")

        let homebrewFacet = app.buttons["applications.manager.uninstaller.facet.homebrew"]
        XCTAssertTrue(homebrewFacet.waitForExistence(timeout: 10),
                      "Expected the Homebrew facet under the Uninstaller's Stores group")
        homebrewFacet.click()

        let state = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN {"
                + "'applications.manager.homebrew.list',"
                + "'applications.manager.homebrew.empty',"
                + "'applications.manager.homebrew.notInstalled'}"))
            .firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 60),
                      "Expected the Homebrew facet to render a valid state")

        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected the shared Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the Applications dashboard"
        )
    }

    /// The Updater pane also exposes a Homebrew facet that reaches a valid
    /// display state.
    func test_applications_updaterHomebrewFacetShowsUpdates() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90), "Expected the Manage button")
        manage.click()

        app.buttons["applications.manager.nav.updater"].click()
        let homebrewFacet = app.buttons["applications.manager.updater.facet.homebrew"]
        XCTAssertTrue(homebrewFacet.waitForExistence(timeout: 10),
                      "Expected the Homebrew facet under the Updater's Stores group")
        homebrewFacet.click()

        let state = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN {"
                + "'applications.manager.homebrew.updates.list',"
                + "'applications.manager.homebrew.updates.empty',"
                + "'applications.manager.homebrew.notInstalled'}"))
            .firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 90),
                      "Expected the Homebrew updates facet to render a valid state")
    }

    // MARK: - Helpers

    private func openApplicationsAndScan() {
        let row = app.buttons["sidebar.applications"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Expected Applications row in sidebar")
        row.click()

        let scan = app.buttons["section.applications.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Applications intro")
        scan.click()
        proceedPastScanAccessPopoverIfNeeded()
    }

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    private func proceedPastScanAccessPopoverIfNeeded() {
        let scanAnyway = app.buttons["fda.popover.scanAnyway"]
        if scanAnyway.waitForExistence(timeout: 3) {
            scanAnyway.click()
        }
    }
}
