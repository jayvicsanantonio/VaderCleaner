// FinalPolishUITests.swift
// End-to-end coverage for the gaps Prompt 27 calls out: full sidebar, Health Monitor cards, Large & Old Files scan, App Uninstaller list, the Preferences tabs, and the menu-bar toggle — exercised against the real app process so the App → ContentView → feature wiring is proven end to end.

import XCTest

/// These tests never trigger destructive controls. Where a scan is required
/// (Large & Old Files) we only wait for a terminal *display* state and never
/// touch Delete — the deletion contracts are covered exhaustively by the
/// view-model unit tests against injected fakes.
final class FinalPolishUITests: XCTestCase {

    private var app: XCUIApplication!

    /// The nine sidebar row identifiers, in `NavigationSection` order. Rows
    /// are located by identifier rather than visible label so the locators
    /// survive rail restyles; these mirror
    /// `NavigationSection.accessibilityIdentifier`. Hard-coded because the
    /// UI-test bundle runs out-of-process and cannot import the app enum;
    /// `NavigationSectionTests` pins the enum side, this pins the rendered side.
    /// Extensions is no longer a top-level section — it lives inside
    /// Applications → Manage My Applications.
    private let sectionIdentifiers = [
        "sidebar.smartScan",
        "sidebar.systemJunk",
        "sidebar.largeOldFiles",
        "sidebar.spaceLens",
        "sidebar.malwareRemoval",
        "sidebar.privacy",
        "sidebar.applications",
        "sidebar.optimization",
        "sidebar.healthMonitor",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Sidebar

    /// Launch → every one of the nine sections is present in the sidebar.
    func test_launch_sidebarShowsAllNineSections() throws {
        dismissOnboardingIfNeeded()

        for identifier in sectionIdentifiers {
            let row = app.buttons[identifier].firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "Expected sidebar to list the \"\(identifier)\" section"
            )
        }
    }

    /// The rail must stay anchored: navigating between detail screens must not
    /// move the sidebar rows vertically. The window is not resized, so the
    /// `sidebar.smartScan` button's absolute Y must be identical before and
    /// after navigating.
    ///
    /// NOTE: this originally contrasted a *short* detail (Extensions, a compact
    /// list) against a *tall* one (Health Monitor's grid) to guard the rail
    /// floating when the detail is short. Extensions is no longer a top-level
    /// section, and every remaining section's detail fills the window height
    /// (scan intros and the Health grid alike), so the short-vs-tall contrast
    /// is gone — this now only smoke-checks that navigation doesn't shift the
    /// rail. Re-pointing it at a genuinely short surface (e.g. the Applications
    /// all-clear dashboard or the Extensions pane) would require running a scan
    /// inside the test.
    func test_railRowPosition_isStableAcrossDetailScreens() throws {
        dismissOnboardingIfNeeded()

        let anchor = app.buttons["sidebar.smartScan"].firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 5),
                      "Expected Smart Scan row in sidebar")

        let privacyRow = app.buttons["sidebar.privacy"].firstMatch
        XCTAssertTrue(privacyRow.waitForExistence(timeout: 5),
                      "Expected Privacy row in sidebar")
        privacyRow.click()
        // Wait until the clicked row reports selection before measuring. The
        // anchor row exists regardless of selection, so waiting on it would
        // return immediately and could sample Y mid-transition; the
        // `.isSelected` trait only flips once the navigation has taken
        // effect and the rail re-rendered.
        waitUntilSelected(privacyRow)
        let yIntroDetail = anchor.frame.origin.y

        let healthRow = app.buttons["sidebar.healthMonitor"].firstMatch
        XCTAssertTrue(healthRow.waitForExistence(timeout: 5),
                      "Expected Health Monitor row in sidebar")
        healthRow.click()
        waitUntilSelected(healthRow)
        let yGridDetail = anchor.frame.origin.y

        XCTAssertEqual(
            yIntroDetail, yGridDetail, accuracy: 1.0,
            "Sidebar rows must not shift vertically when the detail screen "
            + "changes (was \(yIntroDetail) on Privacy, "
            + "\(yGridDetail) on Health Monitor)"
        )
    }

    // MARK: - Health Monitor

    /// Health Monitor must surface at least three stat cards. RAM, CPU, and
    /// Disk are always available on any Mac (battery/SMART depend on
    /// hardware), so asserting those three is both ≥3 and deterministic.
    func test_navigateToHealthMonitor_showsAtLeastThreeStatCards() throws {
        dismissOnboardingIfNeeded()

        let row = app.buttons["sidebar.healthMonitor"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Health Monitor row in sidebar")
        row.click()

        let alwaysPresent = ["health.card.ram", "health.card.cpu", "health.card.disk"]
        for identifier in alwaysPresent {
            let card = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(
                card.waitForExistence(timeout: 10),
                "Expected Health Monitor stat card \"\(identifier)\" to be visible"
            )
        }
    }

    /// Health Monitor is a non-scannable section: it must keep its bespoke
    /// live-stats UI and must NOT pick up the scan-centric shell — no unified
    /// intro screen and no floating Scan button. Regression guard that the
    /// `ScannableSectionContent` wrapper and `FloatingScanOverlay` stay gated
    /// behind `NavigationSection.isScannable`.
    func test_healthMonitor_isNonScannable_hasNoIntroOrScanButton() throws {
        dismissOnboardingIfNeeded()

        let row = app.buttons["sidebar.healthMonitor"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Health Monitor row in sidebar")
        row.click()

        // Wait for the bespoke UI to actually render before asserting
        // absence, so we are not just sampling before the section appeared.
        let ramCard = app.descendants(matching: .any)["health.card.ram"]
        XCTAssertTrue(ramCard.waitForExistence(timeout: 10),
                      "Expected Health Monitor's bespoke stat cards to render")

        XCTAssertFalse(
            app.descendants(matching: .any)["section.intro"].exists,
            "A non-scannable section must not render the unified intro screen"
        )
        XCTAssertFalse(
            app.buttons["section.healthMonitor.scan"].exists,
            "A non-scannable section must not show a floating Scan button"
        )
    }

    // MARK: - Large & Old Files

    /// Sidebar → Large & Old Files → Scan must reach a recognizable state:
    /// the results table, the empty state, or the failed state if the test
    /// host's home directory denies traversal. The scan recursively walks
    /// the entire home directory and there is no mock mode (project policy
    /// forbids one), so on a large real home folder the terminal state may
    /// not arrive within a UI-test window — the scanning indicator is then
    /// accepted as proof the sidebar → view-model → view wiring is alive,
    /// matching the rationale `SpaceLensUITests` already uses for the same
    /// reason. Scan correctness itself is covered exhaustively by
    /// `LargeOldFilesScannerTests` / `LargeOldFilesViewModelTests`.
    func test_largeOldFiles_scan_reachesRecognizableState() throws {
        dismissOnboardingIfNeeded()

        let row = app.buttons["sidebar.largeOldFiles"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Large & Old Files row in sidebar")
        row.click()

        // Scannable sections land on the unified intro first; the scan trigger
        // is the single shell-level floating button.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for Large & Old Files")
        // The per-section identifier proves it is *Large & Old Files's*
        // intro, not merely "an intro" — the "right title" contract.
        let largeOldIntro = app.descendants(matching: .any)["section.intro.largeoldfiles"]
        XCTAssertTrue(largeOldIntro.waitForExistence(timeout: 5),
                      "Expected the Large & Old Files-specific intro identifier")
        let scan = app.buttons["section.largeOldFiles.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Large & Old Files intro")
        scan.click()
        proceedPastScanAccessPopoverIfNeeded()

        // Prefer a terminal state; allow a generous window for the walk.
        // One combined query so an early empty/failed state short-circuits
        // instead of blocking the full timeout waiting only for the table.
        let terminal = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'large-old.table', 'large-old.emptyTitle', 'large-old.errorMessage'}"
            ))
            .firstMatch
        if terminal.waitForExistence(timeout: 120) {
            return
        }

        // Still walking the home directory — the wiring is proven by the
        // in-progress scanning indicator having rendered.
        let scanning = app.descendants(matching: .any)["large-old.scanning"]
        XCTAssertTrue(
            scanning.exists,
            "Expected Large & Old Files to reach the table, empty, failed, or scanning state after a scan"
        )
    }

    // MARK: - Applications → Manage (App Uninstaller)

    /// Sidebar → Applications → Scan → Manage opens the reused App Uninstaller
    /// list. Any real Mac has well over five apps in /Applications, so the list
    /// must contain at least five rows. This proves the merged Applications
    /// section's scan → dashboard → detail wiring end to end.
    func test_applications_manageOpensUninstallerListWithAtLeastFiveApps() throws {
        dismissOnboardingIfNeeded()

        let row = app.buttons["sidebar.applications"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected Applications row in sidebar")
        row.click()

        // Scannable section: land on the unified intro, then trigger the scan
        // via the floating Scan button.
        let scan = app.buttons["section.applications.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Applications intro")
        scan.click()
        proceedPastScanAccessPopoverIfNeeded()

        // The scan discovers installed apps and checks for updates; allow a
        // generous window for the dashboard to land before opening Manage.
        let manage = app.buttons["applications.manageMyApplications"]
        XCTAssertTrue(manage.waitForExistence(timeout: 90),
                      "Expected the Applications dashboard after the scan")
        manage.click()

        // Rows are namespaced `appUninstaller.row.<bundleID>`. Discovery
        // shells out and inspects bundles, so allow a generous window for
        // the first row to appear before counting.
        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'appUninstaller.row.'"))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 45),
                      "Expected the Manage screen to load the installed-app list")

        let rowCount = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'appUninstaller.row.'"))
            .count
        XCTAssertGreaterThanOrEqual(
            rowCount, 5,
            "Expected at least five installed apps in the Manage list, found \(rowCount)"
        )
    }

    // MARK: - Preferences

    /// Cmd+, opens the Settings scene; all four preference tabs must be
    /// reachable and the Menu Bar tab must expose its toggle.
    func test_preferences_allFourTabsAreAccessible() throws {
        dismissOnboardingIfNeeded()

        openPreferences()

        for tab in ["Notifications", "Exclusions", "Startup", "Menu Bar"] {
            let button = preferenceTab(tab)
            XCTAssertTrue(
                button.waitForExistence(timeout: 5),
                "Expected the \"\(tab)\" preferences tab to be accessible"
            )
        }

        preferenceTab("Menu Bar").click()
        let toggle = app.switches["preferences.showMenuBar"]
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 5),
            "Expected the Menu Bar tab to expose the show-in-menu-bar toggle"
        )
    }

    /// Toggling "Show VaderCleaner in the menu bar" off must flip the
    /// control's value. (The status item lives in the system menu bar — a
    /// separate accessibility tree — so its disappearance is verified by
    /// `PreferencesStoreTests` + the `MenuBarExtra(isInserted:)` binding,
    /// not here. This proves the control is wired and writable.)
    func test_preferences_toggleMenuBarOff_flipsTheControl() throws {
        dismissOnboardingIfNeeded()

        openPreferences()
        preferenceTab("Menu Bar").click()

        let toggle = app.switches["preferences.showMenuBar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "Expected the show-in-menu-bar toggle")

        // A macOS Switch reports its state via `value` as a Bool-tagged
        // NSNumber — `as? Int` and `as? String` both fail on it, so
        // normalize through every shape XCUIElement.value can take.
        func isOn() -> Bool {
            switch toggle.value {
            case let n as NSNumber: return n.boolValue
            case let b as Bool:     return b
            case let s as String:   return s == "1"
            case let i as Int:      return i == 1
            default:                return false
            }
        }

        let before = isOn()
        toggle.click()

        // Re-read `value` on each poll via a block predicate (the element
        // arg is ignored) so we observe the post-click state.
        let flippedPoll = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in isOn() != before },
            object: nil
        )
        flippedPoll.expectationDescription = "toggle flipped"
        wait(for: [flippedPoll], timeout: 5)

        // Restore the original value so the test leaves no persisted side
        // effect — `showMenuBar` is written through to real UserDefaults.
        toggle.click()
        let restoredPoll = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in isOn() == before },
            object: nil
        )
        restoredPoll.expectationDescription = "toggle restored"
        wait(for: [restoredPoll], timeout: 5)
    }

    // MARK: - Helpers

    /// Block until a sidebar row carries the `.isSelected` accessibility
    /// trait (set by `railRow` via `.accessibilityAddTraits`). This proves
    /// the navigation actually took effect and the rail re-rendered, which
    /// `waitForExistence` on an always-present row cannot.
    private func waitUntilSelected(_ element: XCUIElement,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: element
        )
        selected.expectationDescription = "sidebar row became selected"
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 5), .completed,
            "Expected the clicked sidebar row to report selection",
            file: file, line: line
        )
    }

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    /// The floating Scan button gates FDA-sensitive sections behind an access
    /// popover when Full Disk Access is missing — which it is on a test host
    /// that dismissed onboarding via "Continue Without Access". Tap "Scan
    /// Anyway" so the scan proceeds and the wiring under test still runs.
    private func proceedPastScanAccessPopoverIfNeeded() {
        let scanAnyway = app.buttons["fda.popover.scanAnyway"]
        if scanAnyway.waitForExistence(timeout: 5) {
            scanAnyway.click()
        }
    }

    private func openPreferences() {
        app.typeKey(",", modifierFlags: .command)
    }

    /// SwiftUI's Settings `TabView` renders its tab items differently across
    /// macOS releases (top-level buttons vs. toolbar buttons vs. radio
    /// buttons). Resolve whichever element type actually carries the label.
    private func preferenceTab(_ label: String) -> XCUIElement {
        let button = app.buttons[label]
        if button.exists { return button }
        let radio = app.radioButtons[label]
        if radio.exists { return radio }
        let toolbarButton = app.toolbars.buttons[label]
        if toolbarButton.exists { return toolbarButton }
        // Fall back to the plain button query so callers still get a usable
        // (possibly not-yet-existent) element to wait on.
        return button
    }
}
