// SmartScanUITests.swift
// End-to-end UI test for Smart Scan — asserts the default landing section renders the unified intro screen and its floating Scan button, and that tapping Scan crosses into the concurrent checklist (working) state, exercising the App → ContentView → SectionIntroView → SmartScanView wiring against the real app process.

import XCTest

/// The fast tests here never wait for a Smart Scan to *finish* — it walks the
/// entire home directory and runs `clamscan` for tens of seconds, and there is
/// no mock mode. The scan / aggregation / run contracts are covered
/// exhaustively by `SmartScanViewModelScanTests` / `SmartScanViewModelRunTests`
/// against injected fakes. The Scan tap below only asserts the section reaches
/// its checklist (working) state and returns immediately — `tearDown`
/// terminates the app, killing the walk.
///
/// The one exception is `test_returningToSmartScan_afterLeavingAReviewOpen_...`,
/// which needs a real results feed and so pays for a whole scan. It is the only
/// automated proof that the Fix disc survives a section switch, because the
/// defect it guards lives in SwiftUI view lifetime and has no unit-testable
/// seam. Budget minutes for it, and expect it to be meaningful only on a Mac
/// with something to clean.
@MainActor
final class SmartScanUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() async throws {
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

    /// Regression: leaving a Review open and switching sections used to strand
    /// the results feed. `SmartScanView` mirrors its local `review` state onto
    /// the view model so the Fix disc — hosted in a separate panel — can hide
    /// behind an open Review, and that mirror was written only by an `onChange`.
    /// ContentView scopes the view's lifetime with `.id(selectedSection)`, so
    /// switching away destroyed `review` without firing the change, leaving the
    /// mirror stuck. The disc stayed hidden, and its tap is the app's only route
    /// into `requestRun()`, so the scan could not be run at all until the user
    /// reopened and closed a Review or pressed Start Over.
    ///
    /// Slow by necessity: the disc only exists on a finished scan with work to
    /// do, and there is no way to seed that state without a mock mode.
    func test_returningToSmartScan_afterLeavingAReviewOpen_restoresTheFixDisc() throws {
        dismissOnboardingIfNeeded()

        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 10), "Expected the floating Scan button")
        scanButton.click()
        proceedPastScanAccessPopoverIfNeeded()

        // A full walk plus clamscan. Generous, because the point of the test is
        // what happens after the feed lands, not how fast it lands.
        let feed = app.descendants(matching: .any)["smartScan.resultsFeed"]
        XCTAssertTrue(
            feed.waitForExistence(timeout: 600),
            "Expected the results feed once the scan finishes"
        )

        let disc = app.buttons["smartScan.run"]
        try XCTSkipUnless(
            disc.waitForExistence(timeout: 15),
            "This Mac's scan found no executable work, so there is no Fix disc to strand"
        )

        // Open whichever Review this machine's plan actually offers.
        let review = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "smartScan.card.", ".review")
        ).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10), "Expected at least one card with a Review affordance")
        review.click()
        // Wait for the disc to *go*, rather than sampling `exists` straight
        // after the click and reading the pre-click state as a pass.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: disc)
        waitForExpectations(timeout: 10)

        // Leave the section with the Review still open, then come back. The
        // Performance intro's own floating Scan button is the cheapest proof
        // the switch actually landed.
        app.buttons["sidebar.performance"].firstMatch.click()
        XCTAssertTrue(
            app.buttons["section.performance.scan"].waitForExistence(timeout: 10),
            "Expected the Performance section after switching"
        )
        app.buttons["sidebar.smartScan"].firstMatch.click()

        XCTAssertTrue(
            feed.waitForExistence(timeout: 10),
            "Expected the results feed again on return — the scan is still finished"
        )
        XCTAssertTrue(
            disc.waitForExistence(timeout: 10),
            "The Fix disc must come back on return; without it the scan cannot be run at all"
        )
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
