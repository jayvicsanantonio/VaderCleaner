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

        // Idle state should expose the Scan button by accessibility identifier.
        let scanButton = app.buttons["system-junk.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5),
                      "Expected Scan button in System Junk idle state")
        scanButton.click()

        // The scan completes once we land on either the preview footer
        // (Total selected label / Clean button) or — if no junk files were
        // found — the empty preview list still rendered.
        let totalSelected = app.staticTexts["system-junk.totalSelected"]
        let cleanButton = app.buttons["system-junk.clean"]

        let appeared = totalSelected.waitForExistence(timeout: 30)
            || cleanButton.waitForExistence(timeout: 1)
        XCTAssertTrue(appeared,
                      "Expected to land on the preview state after a Scan")
    }

    /// Once a scan has landed, visiting another sidebar item and coming back
    /// should preserve the same System Junk session model rather than
    /// rebuilding a fresh idle state.
    func test_systemJunkPreviewPersistsAcrossSidebarNavigation() throws {
        dismissOnboardingIfNeeded()

        let sidebarRow = app.buttons["sidebar.systemJunk"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected System Junk row in sidebar")
        sidebarRow.click()

        let scanButton = app.buttons["system-junk.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5),
                      "Expected Scan button in System Junk idle state")
        scanButton.click()

        let totalSelected = app.staticTexts["system-junk.totalSelected"]
        let cleanButton = app.buttons["system-junk.clean"]
        let appeared = totalSelected.waitForExistence(timeout: 30)
            || cleanButton.waitForExistence(timeout: 1)
        XCTAssertTrue(appeared,
                      "Expected to land on the preview state after a Scan")

        let smartScanRow = app.buttons["sidebar.smartScan"].firstMatch
        XCTAssertTrue(smartScanRow.waitForExistence(timeout: 5),
                      "Expected Smart Scan row in sidebar")
        smartScanRow.click()

        sidebarRow.click()

        let previewStillVisible = totalSelected.waitForExistence(timeout: 5)
            || cleanButton.waitForExistence(timeout: 1)
        XCTAssertTrue(previewStillVisible,
                      "Expected System Junk preview state to persist after sidebar navigation")
        XCTAssertFalse(app.buttons["system-junk.scan"].exists,
                       "Expected System Junk not to reset to idle after sidebar navigation")
    }

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }
}
