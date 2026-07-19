// SmartScanUITests.swift
// End-to-end UI test for Smart Scan — asserts the default landing section renders the unified intro screen and its floating Scan button, and that tapping Scan crosses into the concurrent checklist (working) state, exercising the App → ContentView → SectionIntroView → SmartScanView wiring against the real app process.

import XCTest

/// We never wait for a Smart Scan to *finish* here — it walks the entire home
/// directory and runs `clamscan` for tens of seconds, which would make the
/// test slow and flaky, and there is no mock mode. The scan / aggregation /
/// run contracts are covered exhaustively by `SmartScanViewModelScanTests` /
/// `SmartScanViewModelRunTests` against injected fakes. The Scan tap below
/// only asserts the section reaches its checklist (working) state and
/// returns immediately — `tearDown` terminates the app, killing the walk.
final class SmartScanUITests: XCTestCase {

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

    func test_smartScanIsDefaultLanding_revealsIntroScreen() throws {
        dismissOnboardingIfNeeded()

        // Smart Scan is the default selected section, so the unified intro and
        // its floating Scan button should be present without any navigation.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(
            intro.waitForExistence(timeout: 10),
            "Expected the Smart Scan intro screen to be the default landing view"
        )
        // The per-section identifier proves it is *Smart Scan's* intro on
        // screen, not merely "an intro" — the "right title" contract.
        let smartScanIntro = app.descendants(matching: .any)["section.intro.smartscan"]
        XCTAssertTrue(
            smartScanIntro.waitForExistence(timeout: 5),
            "Expected the Smart Scan-specific intro identifier"
        )
        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 5),
            "Expected the floating Scan button on the Smart Scan intro"
        )
    }

    /// Default landing → tap the floating Scan → the section must cross from
    /// the intro into the concurrent checklist. We assert only the
    /// transition, never completion (see the file-level note).
    func test_smartScan_tapScan_entersChecklist() throws {
        dismissOnboardingIfNeeded()

        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Expected the floating Scan button before starting"
        )
        scanButton.click()
        proceedPastScanAccessPopoverIfNeeded()

        let checklist = app.descendants(matching: .any)["smartScan.scanning"]
        XCTAssertTrue(
            checklist.waitForExistence(timeout: 10),
            "Expected the scanning checklist after tapping Scan"
        )
        // The checklist renders one grid tile per care domain, keyed by the
        // stable domain raw values — the honest-concurrency contract.
        for domain in ["systemJunk", "myClutter", "malware", "browserPrivacy", "applications", "performance"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["smartScan.scanning.tile.\(domain)"].waitForExistence(timeout: 5),
                "Expected a checklist tile for the \(domain) domain"
            )
        }
    }

    /// Dismisses the Full Disk Access onboarding sheet when the test machine
    /// hasn't granted FDA, so the intro assertions can run either way.
    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    /// The floating Scan button gates FDA-sensitive sections behind an access
    /// popover when Full Disk Access is missing. Tap "Scan Anyway" so the
    /// wiring under test still runs.
    private func proceedPastScanAccessPopoverIfNeeded() {
        let scanAnyway = app.buttons["fda.popover.scanAnyway"]
        if scanAnyway.waitForExistence(timeout: 3) {
            scanAnyway.click()
        }
    }
}
