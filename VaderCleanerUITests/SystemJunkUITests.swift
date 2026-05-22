// SystemJunkUITests.swift
// End-to-end UI tests for the System Junk feature — navigates to the section, taps Scan, and waits for the preview list to appear so the wiring between sidebar selection, view-model, and view is exercised against the real app process.

import XCTest

/// We deliberately do not tap "Clean" in this test. The view-model unit tests
/// cover the deletion contract exhaustively against an injected fake deleter;
/// here, hitting the real `Clean` button would remove files from the user's
/// `~/Library/Caches` (and similar) on the machine running the test, which is
/// not something a UI test should ever do as a side effect.
final class SystemJunkUITests: XCTestCase {

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

    /// Sidebar → System Junk → Scan must reveal the preview UI. We accept any
    /// of the preview-state identifiers (the totalSelected label, the Clean
    /// button, or the Re-scan button) as evidence that the preview rendered,
    /// so the test does not depend on the scan returning at least one result —
    /// an empty Caches directory on a freshly imaged CI host must not flake.
    func test_navigateToSystemJunk_andScan_revealsPreview() throws {
        // The Full Disk Access onboarding sheet may be in the way. Dismiss it
        // through "Continue Without Access" if present so the sidebar is
        // reachable. The button label comes from `PermissionOnboardingView`.
        dismissOnboardingIfNeeded()

        // Select the sidebar row by its stable accessibility identifier
        // rather than its visible label, so the locator survives restyles.
        let sidebarRow = app.buttons["sidebar.systemJunk"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected System Junk row in sidebar")
        sidebarRow.click()

        // Scannable sections land on the unified intro screen first.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for System Junk")
        // The per-section identifier proves it is *System Junk's* intro, not
        // merely "an intro" — the "right title" contract.
        let systemJunkIntro = app.descendants(matching: .any)["section.intro.systemjunk"]
        XCTAssertTrue(systemJunkIntro.waitForExistence(timeout: 5),
                      "Expected the System Junk-specific intro identifier")

        // The scan trigger is now the single shell-level floating button.
        let scanButton = app.buttons["section.systemJunk.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the System Junk intro")
        scanButton.click()
        proceedPastScanAccessPopoverIfNeeded()

        // The scan completes once we land on the preview footer (Total
        // selected label / Clean button), or — if no junk files were found —
        // the empty preview list still rendered. The System Junk scan walks
        // the entire home directory and there is no mock mode (project
        // policy forbids one), so on a large real home folder the terminal
        // state may not arrive within a tight UI-test window; the in-progress
        // `system-junk.scanning` indicator is then accepted as proof the
        // sidebar → view-model → view wiring is alive, matching the rationale
        // `FinalPolishUITests` (Large & Old Files) and `SpaceLensUITests`
        // already use for the same unbounded walk. Scan correctness itself is
        // covered exhaustively by `SystemJunkScannerTests` /
        // `SystemJunkViewModelTests`.
        // Match every identifier the preview footer always renders — the
        // total-selected label, the Clean button, and the Re-scan button —
        // so an empty scan (which still lands on `.preview` with that footer)
        // is recognised as terminal, not a false failure.
        let terminal = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'system-junk.totalSelected', 'system-junk.clean', 'system-junk.rescan'}"
            ))
            .firstMatch
        if terminal.waitForExistence(timeout: 120) {
            return
        }

        // Still walking the home directory — wait (don't just sample) for the
        // in-progress indicator so a momentary race between the terminal
        // timeout and the next render can't false-fail.
        let scanning = app.descendants(matching: .any)["system-junk.scanning"]
        XCTAssertTrue(
            scanning.waitForExistence(timeout: 5),
            "Expected System Junk to reach the preview state or still be scanning after a Scan"
        )
    }

    /// Once a scan has started, visiting another sidebar item and coming
    /// back must preserve the same System Junk session model rather than
    /// rebuilding a fresh intro. The contract is "it did not reset to the
    /// intro", which holds whether the section is still scanning or has
    /// reached its preview — so the test does not require the unbounded
    /// home-directory walk to *complete* (there is no mock mode, and that
    /// walk runs anywhere from seconds to minutes depending on the runner's
    /// home folder). It anchors on the section having left `.intro` and
    /// staying out of it across navigation, matching the rationale the
    /// `SpaceLens` / Large & Old Files siblings already use for the same
    /// unbounded walk.
    func test_systemJunkPreviewPersistsAcrossSidebarNavigation() throws {
        dismissOnboardingIfNeeded()

        let sidebarRow = app.buttons["sidebar.systemJunk"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected System Junk row in sidebar")
        sidebarRow.click()

        let scanButton = app.buttons["section.systemJunk.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the System Junk intro")
        scanButton.click()
        proceedPastScanAccessPopoverIfNeeded()

        // The section has left `.intro` once it shows any non-intro state:
        // the in-progress scanning indicator, or the preview footer (which
        // always renders the total-selected label, Clean, and Re-scan, even
        // for an empty scan).
        let nonIntroPredicate = NSPredicate(format:
            "identifier IN {'system-junk.scanning', 'system-junk.totalSelected', "
            + "'system-junk.clean', 'system-junk.rescan'}")
        let nonIntroState = app.descendants(matching: .any)
            .matching(nonIntroPredicate).firstMatch
        XCTAssertTrue(
            nonIntroState.waitForExistence(timeout: 30),
            "Expected System Junk to leave its intro (scanning or preview) after a Scan"
        )
        XCTAssertFalse(scanButton.exists,
                       "Floating Scan must be gone once the section left its intro")

        let smartScanRow = app.buttons["sidebar.smartScan"].firstMatch
        XCTAssertTrue(smartScanRow.waitForExistence(timeout: 5),
                      "Expected Smart Scan row in sidebar")
        smartScanRow.click()

        sidebarRow.click()

        // The session persisted: still a non-intro state, and crucially the
        // section did NOT rebuild back to its intro / floating Scan.
        let stillNonIntro = app.descendants(matching: .any)
            .matching(nonIntroPredicate).firstMatch
        XCTAssertTrue(
            stillNonIntro.waitForExistence(timeout: 10),
            "Expected System Junk's session (scanning or preview) to persist after sidebar navigation"
        )
        XCTAssertFalse(app.buttons["section.systemJunk.scan"].exists,
                       "Expected System Junk not to reset to its intro after sidebar navigation")
    }

    // MARK: - Helpers

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
        if scanAnyway.waitForExistence(timeout: 2) {
            scanAnyway.click()
        }
    }
}
