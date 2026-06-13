// PrivacyUITests.swift
// End-to-end coverage for the Privacy section — intro → Scan → dashboard grid → per-category review screens — exercised against the real app process.

import XCTest

/// These tests never trigger destructive controls. They drive the scan and
/// open the dashboard's review screens, but stop at display states — the
/// clear side-effects are covered by the view-model unit tests.
final class PrivacyUITests: XCTestCase {

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

    /// Scan → the dashboard appears with the headline total, the View All
    /// Data and Re-scan header buttons, and at most four recommendation
    /// cards. There is no pinned footer — the selection total and Clear live
    /// in the catalog.
    func test_privacy_scanShowsDashboard() throws {
        dismissOnboardingIfNeeded()
        openPrivacyAndScan()

        let dashboard = app.descendants(matching: .any)["privacy.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Privacy dashboard after the scan")

        XCTAssertTrue(app.descendants(matching: .any)["privacy.foundTotal"].waitForExistence(timeout: 5),
                      "Expected the headline total on the dashboard")
        XCTAssertTrue(app.buttons["privacy.viewAllData"].waitForExistence(timeout: 5),
                      "Expected the View All Data button on the dashboard header")
        XCTAssertTrue(app.buttons["privacy.rescan"].waitForExistence(timeout: 5),
                      "Expected the Re-scan button next to View All Data")
        XCTAssertFalse(app.descendants(matching: .any)["privacy.totalSelected"].exists,
                       "The selection total must not render on the dashboard — it lives in the catalog")

        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'privacy.card.'")
        )
        XCTAssertGreaterThanOrEqual(cards.count, 1,
                                    "Expected at least one card — the System card renders even with no findings")
        XCTAssertLessThanOrEqual(cards.count, 4,
                                 "The dashboard grid is capped at four recommendation cards")
    }

    /// A category card's Review opens the Privacy Manager catalog — the same
    /// surface View All Data opens — with its Clear bar, and Back returns to
    /// the dashboard. Which category cards appear depends on the host's
    /// browser data, so this exercises whichever card is present; on a host
    /// with no findings only the System card renders and the test accepts that.
    func test_privacy_categoryCardOpensCatalogAndBackReturns() throws {
        dismissOnboardingIfNeeded()
        openPrivacyAndScan()

        let dashboard = app.descendants(matching: .any)["privacy.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Privacy dashboard after the scan")

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN {"
                + "'privacy.card.history','privacy.card.downloads',"
                + "'privacy.card.cookies','privacy.card.cache',"
                + "'privacy.card.savedForms'}"))
            .firstMatch

        guard card.waitForExistence(timeout: 10) else {
            // No browser findings → only the System card; nothing to open.
            XCTAssertTrue(app.buttons["privacy.card.system"].exists,
                          "With no category cards the System card must still render")
            return
        }

        card.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.catalog"].waitForExistence(timeout: 10),
            "Expected a category card's Review to open the Privacy Manager catalog"
        )
        XCTAssertTrue(app.descendants(matching: .any)["privacy.totalSelected"].waitForExistence(timeout: 5),
                      "Expected the Clear bar's selection total inside the catalog")
        XCTAssertTrue(app.buttons["privacy.clear"].exists,
                      "Expected the Clear button inside the catalog")

        let back = app.buttons["privacy.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard"
        )
    }

    /// The System Traces card opens the catalog on its System pane with the
    /// Recent Items toggle. The System card is the first one dropped by the
    /// four-card cap, so on a host with four or more category findings it
    /// isn't on the dashboard and the test accepts that — the catalog test
    /// covers the System pane host-independently.
    func test_privacy_systemCardOpensCatalogSystemPane() throws {
        dismissOnboardingIfNeeded()
        openPrivacyAndScan()

        let dashboard = app.descendants(matching: .any)["privacy.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Privacy dashboard after the scan")

        let systemCard = app.buttons["privacy.card.system"]
        guard systemCard.waitForExistence(timeout: 10) else {
            // Four or more category cards → the System card is capped out.
            return
        }
        systemCard.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.catalog"].waitForExistence(timeout: 10),
            "Expected the System card to open the Privacy Manager catalog"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.row.recentItems"].waitForExistence(timeout: 5),
            "Expected the Recent Items toggle row on the catalog's System pane"
        )

        let back = app.buttons["privacy.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard"
        )
    }

    /// View All Data opens the Privacy Manager catalog with its per-category +
    /// System sub-navigation and the Clear bar; the System pane renders the
    /// Recent Items toggle and Back returns to the dashboard.
    func test_privacy_viewAllDataOpensCatalog() throws {
        dismissOnboardingIfNeeded()
        openPrivacyAndScan()

        let viewAll = app.buttons["privacy.viewAllData"]
        XCTAssertTrue(viewAll.waitForExistence(timeout: 90),
                      "Expected the View All Data button after the scan")
        viewAll.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.catalog"].waitForExistence(timeout: 10),
            "Expected the Privacy Manager catalog"
        )

        // The sub-navigation lists every data category plus System.
        for navID in ["privacy.catalog.nav.history",
                      "privacy.catalog.nav.downloads",
                      "privacy.catalog.nav.cookies",
                      "privacy.catalog.nav.cache",
                      "privacy.catalog.nav.savedForms",
                      "privacy.catalog.nav.system"] {
            XCTAssertTrue(app.buttons[navID].waitForExistence(timeout: 5),
                          "Expected sub-nav item \(navID)")
        }

        app.buttons["privacy.catalog.nav.system"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.row.recentItems"].waitForExistence(timeout: 5),
            "Expected the Recent Items toggle row on the catalog's System pane"
        )

        // The Clear bar (selection total + Clear) is pinned inside the catalog.
        XCTAssertTrue(app.descendants(matching: .any)["privacy.totalSelected"].exists,
                      "Expected the Clear bar's selection total inside the catalog")
        XCTAssertTrue(app.buttons["privacy.clear"].exists,
                      "Expected the Clear button inside the catalog")

        let back = app.buttons["privacy.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard"
        )
    }

    // MARK: - Helpers

    /// Navigate to Privacy and trigger the scan via the floating button.
    private func openPrivacyAndScan() {
        let row = app.buttons["sidebar.privacy"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Privacy row in sidebar")
        row.click()

        let scan = app.buttons["section.privacy.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Privacy intro")
        scan.click()
        proceedPastScanAccessPopoverIfNeeded()
    }

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    /// Without Full Disk Access the scan button raises the access popover —
    /// proceed with "Scan Anyway" so the test exercises the dashboard either way.
    private func proceedPastScanAccessPopoverIfNeeded() {
        let scanAnyway = app.buttons["fda.popover.scanAnyway"]
        if scanAnyway.waitForExistence(timeout: 3) {
            scanAnyway.click()
        }
    }
}
