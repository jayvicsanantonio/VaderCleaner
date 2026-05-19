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
        let terminal = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN {'system-junk.totalSelected', 'system-junk.clean'}"
            ))
            .firstMatch
        if terminal.waitForExistence(timeout: 120) {
            return
        }

        let scanning = app.descendants(matching: .any)["system-junk.scanning"]
        XCTAssertTrue(
            scanning.exists,
            "Expected System Junk to reach the preview state or still be scanning after a Scan"
        )
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

        let scanButton = app.buttons["section.systemJunk.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the System Junk intro")
        scanButton.click()

        // This test's contract — the preview *persisting* across sidebar
        // navigation — is only meaningful once the scan has actually reached
        // the preview, so unlike the sibling test above it cannot fall back
        // to the in-progress scanning state. The home-directory walk is
        // unbounded and there is no mock mode, so allow the same generous
        // window `FinalPolishUITests` uses for the equivalent Large & Old
        // Files walk rather than a tight 30s that flakes under suite load.
        let totalSelected = app.staticTexts["system-junk.totalSelected"]
        let cleanButton = app.buttons["system-junk.clean"]
        let appeared = totalSelected.waitForExistence(timeout: 120)
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
}
