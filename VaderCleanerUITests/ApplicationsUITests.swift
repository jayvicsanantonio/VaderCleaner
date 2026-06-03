// ApplicationsUITests.swift
// End-to-end coverage for the merged Applications section — intro → Scan → dashboard grid → reused detail screens — exercised against the real app process.

import XCTest

/// These tests never trigger destructive controls. They drive the scan and
/// open the dashboard's detail screens, but stop at display states — the
/// uninstall / update side-effects are covered by the view-model unit tests.
final class ApplicationsUITests: XCTestCase {

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

    /// Selecting Applications lands on the unified scan intro (it is a
    /// scannable section now), with its per-section intro identifier and the
    /// floating Scan button — not a list that auto-loads.
    func test_applications_showsScanIntro() throws {
        dismissOnboardingIfNeeded()

        let row = app.buttons["sidebar.applications"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Applications row in sidebar")
        row.click()

        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for Applications")
        let applicationsIntro = app.descendants(matching: .any)["section.intro.applications"]
        XCTAssertTrue(applicationsIntro.waitForExistence(timeout: 5),
                      "Expected the Applications-specific intro identifier")
        let scan = app.buttons["section.applications.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Applications intro")
    }

    /// Scan → the dashboard grid appears with the Updates and Manage cards.
    func test_applications_scanShowsDashboardGrid() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let dashboard = app.descendants(matching: .any)["applications.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Applications dashboard grid after the scan")

        XCTAssertTrue(app.buttons["applications.card.updates"].waitForExistence(timeout: 5),
                      "Expected the Updates card on the dashboard")
        XCTAssertTrue(app.buttons["applications.card.manage"].exists,
                      "Expected the Manage card on the dashboard")
        XCTAssertTrue(app.buttons["applications.card.installationFiles"].exists,
                      "Expected the Installation Files card on the dashboard")
        XCTAssertTrue(app.buttons["applications.card.unsupported"].exists,
                      "Expected the Unsupported Applications card on the dashboard")
        XCTAssertTrue(app.buttons["applications.card.unused"].exists,
                      "Expected the Unused Applications card on the dashboard")
        XCTAssertTrue(app.buttons["applications.card.leftovers"].exists,
                      "Expected the App Leftovers card on the dashboard")
    }

    /// The Installation Files card opens its review screen, and Back returns to
    /// the dashboard.
    func test_applications_installationFilesCardOpensReviewAndBackReturns() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let card = app.buttons["applications.card.installationFiles"]
        XCTAssertTrue(card.waitForExistence(timeout: 90),
                      "Expected the Installation Files card after the scan")
        card.click()

        // Either the installer list or its empty state must render — both are
        // valid display states depending on what's in Downloads/Desktop.
        let reviewState = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'applications.installationFiles', 'applications.installationFiles.empty'}"
            ))
            .firstMatch
        XCTAssertTrue(reviewState.waitForExistence(timeout: 10),
                      "Expected the Installation Files review screen to render")

        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard grid"
        )
    }

    /// The Updates card opens the reused App Updater screen, and Back returns
    /// to the dashboard.
    func test_applications_updatesCardOpensUpdaterAndBackReturns() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let updatesCard = app.buttons["applications.card.updates"]
        XCTAssertTrue(updatesCard.waitForExistence(timeout: 90),
                      "Expected the Updates card after the scan")
        updatesCard.click()

        // The reused App Updater screen reaches one of its display states.
        let updaterState = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'appUpdater.loading', 'appUpdater.upToDate', 'appUpdater.check', 'appUpdater.errorMessage'}"
            ))
            .firstMatch
        XCTAssertTrue(updaterState.waitForExistence(timeout: 30),
                      "Expected the reused App Updater screen to render")

        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard grid"
        )
    }

    // MARK: - Helpers

    /// Navigate to Applications and trigger the scan via the floating button.
    private func openApplicationsAndScan() {
        let row = app.buttons["sidebar.applications"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Applications row in sidebar")
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

    /// Applications is not Full-Disk-Access-gated, so the access popover should
    /// not appear — but tap "Scan Anyway" defensively if it ever does.
    private func proceedPastScanAccessPopoverIfNeeded() {
        let scanAnyway = app.buttons["fda.popover.scanAnyway"]
        if scanAnyway.waitForExistence(timeout: 3) {
            scanAnyway.click()
        }
    }
}
