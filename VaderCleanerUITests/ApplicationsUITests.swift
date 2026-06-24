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

    /// Scan → the dashboard appears showing only recommendation cards (or the
    /// all-clear state when nothing needs attention). Updates is one of the
    /// ranked cards now; the old standalone Manage card is gone — Manage lives
    /// behind the header button.
    func test_applications_scanShowsDashboard() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let dashboard = app.descendants(matching: .any)["applications.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Applications dashboard after the scan")

        // Which recommendation cards appear depends on the machine, so assert
        // the dashboard reaches a valid state: at least one recommendation card,
        // or the all-clear state.
        let validState = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN {"
                + "'applications.card.unsupported','applications.card.unused',"
                + "'applications.card.updates','applications.card.leftovers',"
                + "'applications.card.installationFiles',"
                + "'applications.dashboard.allClear'}"))
            .firstMatch
        XCTAssertTrue(validState.waitForExistence(timeout: 10),
                      "Expected a recommendation card or the all-clear state")

        // The standalone Manage card is gone — Manage is the header button now.
        XCTAssertFalse(app.buttons["applications.card.manage"].exists,
                       "The Manage card was replaced by the header button")
        XCTAssertTrue(app.buttons["applications.manageMyApplications"].waitForExistence(timeout: 5),
                      "Expected the Manage My Applications header button")
    }

    /// A recommendation card opens its review screen, and Back returns to the
    /// dashboard. The dashboard now shows only cleanup categories that have
    /// findings, so the exact cards depend on the host — this exercises
    /// whichever recommendation card is present rather than assuming a specific
    /// one. On a host with nothing to clean up the dashboard shows the all-clear
    /// state and there is no card to open, which the test accepts.
    func test_applications_recommendationCardOpensReviewAndBackReturns() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let dashboard = app.descendants(matching: .any)["applications.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Applications dashboard after the scan")

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN {"
                + "'applications.card.unused','applications.card.unsupported',"
                + "'applications.card.leftovers','applications.card.installationFiles'}"))
            .firstMatch

        guard card.waitForExistence(timeout: 10) else {
            // No findings → the all-clear state; there is no card to open.
            XCTAssertTrue(
                app.descendants(matching: .any)["applications.dashboard.allClear"].exists,
                "With no recommendation cards the dashboard must show the all-clear state"
            )
            return
        }

        card.click()

        // Whichever review screen opened, it carries the shared Back control.
        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "Expected a recommendation card to open a review screen with a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard"
        )
    }

    /// The Manage My Applications button opens the Applications Manager catalog
    /// with its Uninstaller / Updater / Extensions / Leftovers sub-navigation;
    /// switching panes works and Back returns to the dashboard.
    func test_applications_manageOpensManagerCatalog() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90),
                      "Expected the Manage My Applications button after the scan")
        manage.click()

        XCTAssertTrue(app.descendants(matching: .any)["applications.manager"].waitForExistence(timeout: 10),
                      "Expected the Applications Manager catalog")
        for navID in ["applications.manager.nav.uninstaller",
                      "applications.manager.nav.updater",
                      "applications.manager.nav.extensions",
                      "applications.manager.nav.leftovers"] {
            XCTAssertTrue(app.buttons[navID].waitForExistence(timeout: 5),
                          "Expected sub-nav item \(navID)")
        }

        // Switch to the Updater pane — either the manager's "everything is in
        // order" empty state (no updates) or the checkbox list of updates.
        app.buttons["applications.manager.nav.updater"].click()
        let updaterState = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'applications.manager.updater.empty', 'applications.manager.updater.list'}"
            ))
            .firstMatch
        XCTAssertTrue(updaterState.waitForExistence(timeout: 30),
                      "Expected the Updater pane to render its empty state or the updates list")

        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard grid"
        )
    }

    /// The Manager's Extensions pane renders the reused Extensions Manager
    /// screen, and Back returns to the dashboard. (Extensions used to be a
    /// top-level sidebar section; it now lives inside Manage My Applications.)
    func test_applications_manageExtensionsPaneRenders() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90),
                      "Expected the Manage My Applications button after the scan")
        manage.click()

        let extensionsNav = app.buttons["applications.manager.nav.extensions"]
        XCTAssertTrue(extensionsNav.waitForExistence(timeout: 10),
                      "Expected the Extensions sub-nav item")
        extensionsNav.click()

        // The Extensions pane reaches a display state: the empty state or the
        // checkbox list of discovered extensions.
        let extensionsState = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'applications.manager.extensions.empty', 'applications.manager.extensions.list'}"
            ))
            .firstMatch
        XCTAssertTrue(extensionsState.waitForExistence(timeout: 30),
                      "Expected the Extensions pane to render")

        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard grid"
        )
    }

    /// The Updates recommendation card deep-links into the Manager's Updater
    /// pane (rather than its own review screen), and Back returns to the
    /// dashboard. Whether updates exist depends on the host, so the test accepts
    /// the card's absence — mirroring the other host-dependent guards.
    func test_applications_updatesCardOpensUpdaterPane() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let dashboard = app.descendants(matching: .any)["applications.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 90),
                      "Expected the Applications dashboard after the scan")

        let updatesCard = app.buttons["applications.card.updates"]
        guard updatesCard.waitForExistence(timeout: 10) else {
            // No updates available on this host → no Updates card to open.
            return
        }

        updatesCard.click()

        // The deep-link lands on the Manager's Updater pane, in one of its
        // display states (empty state or the checkbox list of updates).
        let updaterState = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'applications.manager.updater.empty', 'applications.manager.updater.list'}"
            ))
            .firstMatch
        XCTAssertTrue(updaterState.waitForExistence(timeout: 30),
                      "Expected the Updates card to deep-link into the Updater pane")

        let back = app.buttons["applications.backToDashboard"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected a Back control")
        back.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["applications.dashboard"].waitForExistence(timeout: 5),
            "Expected Back to return to the dashboard grid"
        )
    }

    /// The Uninstaller pane renders the app list, the search + Sort by controls,
    /// and a footer that starts with nothing selected. This drives display
    /// state only — it never presses the destructive Uninstall button.
    func test_applications_uninstallerPaneRendersListAndFooter() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90),
                      "Expected the Manage My Applications button after the scan")
        manage.click()

        // The Uninstaller pane is the default; its list and footer appear.
        XCTAssertTrue(app.descendants(matching: .any)["applications.manager.uninstaller.list"].waitForExistence(timeout: 30),
                      "Expected the uninstaller app list")
        XCTAssertTrue(app.descendants(matching: .any)["applications.manager.summary"].waitForExistence(timeout: 5),
                      "Expected the footer selection summary")
        XCTAssertTrue(app.descendants(matching: .any)["applications.manager.sort"].waitForExistence(timeout: 5),
                      "Expected the Sort by control")

        // The Uninstall action exists and is disabled until something is checked.
        let uninstall = app.buttons["applications.manager.uninstall"]
        XCTAssertTrue(uninstall.waitForExistence(timeout: 5), "Expected the Uninstall footer action")
        XCTAssertFalse(uninstall.isEnabled, "Uninstall must be disabled with nothing selected")
    }

    /// The Leftovers pane renders its Installers / Leftover Files sections and a
    /// Remove footer action (disabled until something is selected).
    func test_applications_leftoversPaneRenders() throws {
        dismissOnboardingIfNeeded()
        openApplicationsAndScan()

        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90),
                      "Expected the Manage My Applications button after the scan")
        manage.click()

        let leftoversNav = app.buttons["applications.manager.nav.leftovers"]
        XCTAssertTrue(leftoversNav.waitForExistence(timeout: 10), "Expected the Leftovers nav item")
        leftoversNav.click()

        let remove = app.buttons["applications.manager.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "Expected the Remove footer action")
        XCTAssertFalse(remove.isEnabled, "Remove must be disabled with nothing selected")
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
