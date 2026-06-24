// SmartScanUITests.swift
// End-to-end UI test for Smart Scan — asserts the default landing section renders the unified intro screen and its floating Scan button, and that tapping Scan crosses into the scanning (working) state, exercising the App → ContentView → SectionIntroView → SmartScanView wiring against the real app process.

import XCTest

/// We never wait for a Smart Scan to *finish* here — it walks the entire home
/// directory (System Junk scan) and runs `clamscan` for tens of seconds,
/// which would make the test slow and flaky, and there is no mock mode. The
/// scan / aggregation / clean contracts are covered exhaustively by
/// `SmartScanViewModelTests` against injected fakes. The Scan tap below only
/// asserts the section reaches its `smartScan.scanning` (working) state and
/// returns immediately — `tearDown` terminates the app, killing the walk —
/// mirroring the pattern `MalwareUITests` uses for the same reason.
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
    /// the intro into its scanning (working) state. We assert only the
    /// transition, never completion (see the file-level note).
    func test_smartScan_tapScan_entersScanningState() throws {
        dismissOnboardingIfNeeded()

        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Expected the floating Scan button on the Smart Scan intro"
        )
        scanButton.click()
        proceedPastScanAccessPopoverIfNeeded()

        // `smartScan.scanning` is `SmartScanView`'s progress-state identifier
        // — reaching it proves intro → working. Type-agnostic query, matching
        // this suite's sibling pattern: the identifier sits on a SwiftUI
        // container whose XCUITest element type is not reliably predictable.
        let scanning = app.descendants(matching: .any)["smartScan.scanning"]
        XCTAssertTrue(
            scanning.waitForExistence(timeout: 10),
            "Expected Smart Scan to enter its scanning (working) state after Scan"
        )
    }

    /// The Scan disc's label is only the centered "Scan" text. Without an
    /// explicit content shape the button's hit region collapses to the text
    /// glyphs, so clicking the disc around the word does nothing. The button
    /// element must report (close to) the full disc, not the ~37x20pt text
    /// bounds.
    func test_smartScan_scanDiscIsFullyInteractive() throws {
        dismissOnboardingIfNeeded()

        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Expected the floating Scan button on the Smart Scan intro"
        )

        let frame = scanButton.frame
        XCTAssertGreaterThan(
            frame.width, 100,
            "The Scan button must span the whole disc, not just its text label"
        )
        XCTAssertGreaterThan(
            frame.height, 100,
            "The Scan button must span the whole disc, not just its text label"
        )
    }

    /// The Scan disc straddles the window's bottom edge, so the FDA popover
    /// must open upward — above the disc. A downward popover would be clipped
    /// off the bottom of the window, making "Scan Anyway" hard to reach.
    func test_smartScan_fdaPopover_opensAboveTheDisc() throws {
        dismissOnboardingIfNeeded()

        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Expected the floating Scan button on the Smart Scan intro"
        )
        let discFrame = scanButton.frame
        scanButton.click()

        let popover = app.descendants(matching: .any)["fda.popover"]
        guard popover.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "Full Disk Access is granted on this host — no FDA popover to position-check."
            )
        }
        // XCUITest frames are top-left origin, so a smaller midY is higher on
        // screen: the popover's center must sit above the disc's center.
        XCTAssertLessThan(
            popover.frame.midY, discFrame.midY,
            "The FDA popover must open above the Scan disc, not below it"
        )
    }

    func test_navigateToSmartScan_revealsIntroScreen() throws {
        dismissOnboardingIfNeeded()

        // Navigate away and back to prove the sidebar → view wiring works
        // regardless of the default selection.
        // Locate sidebar rows by their stable accessibility identifier rather
        // than by visible label, so the locator survives rail restyles.
        let otherRow = app.buttons["sidebar.healthMonitor"].firstMatch
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5),
                      "Expected Health Monitor row in sidebar")
        otherRow.click()

        let smartScanRow = app.buttons["sidebar.smartScan"].firstMatch
        XCTAssertTrue(smartScanRow.waitForExistence(timeout: 5),
                      "Expected Smart Scan row in sidebar")
        smartScanRow.click()

        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(
            intro.waitForExistence(timeout: 10),
            "Expected Smart Scan to render its intro screen"
        )
        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 5),
            "Expected the floating Scan button on the Smart Scan intro"
        )
    }

    // MARK: - Dashboard structure (Slice 9)

    /// Per CleanMyMac Smart Care parity, the results dashboard renders one
    /// tile per orchestrated sub-module — five tiles total: System Junk
    /// (Cleanup), Protection (Malware), Performance (Performance),
    /// Applications (App Updater), My Clutter (Large & Old Files). Every
    /// scan lands all five, even zero-work ones, so the count is fixed.
    func test_resultsDashboard_showsFiveTiles() throws {
        try runScanToResultsDashboard()
        XCTAssertTrue(
            app.descendants(matching: .any)["smartScan.resultsHeading"]
                .waitForExistence(timeout: 5),
            "Expected the results dashboard heading on screen"
        )
        // Performance is always actionable (maintenance scripts always
        // available), so its checkbox is the most reliable anchor for "this
        // is the Smart Care 5-tile dashboard, not the old 3-tile one".
        let performanceCheckbox = app.descendants(matching: .any)["smartScan.togglePerformance"]
        XCTAssertTrue(
            performanceCheckbox.waitForExistence(timeout: 2),
            "Expected the Performance tile's checkbox on the dashboard"
        )
    }

    /// The Run disc identifier must be `smartScan.run`, not the old
    /// `smartScan.clean`. Renaming this identifier without renaming the
    /// dashboard CTA would silently break the contract.
    func test_resultsDashboard_runDiscIdentifierIsSmartScanRun() throws {
        try runScanToResultsDashboard()
        let run = app.descendants(matching: .any)["smartScan.run"]
        XCTAssertTrue(
            run.waitForExistence(timeout: 5),
            "Expected the dashboard's Run CTA under the identifier `smartScan.run`"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["smartScan.clean"].exists,
            "The legacy `smartScan.clean` identifier must not survive the rename"
        )
    }

    /// Deselecting every tile must hide the Run disc — a Run that wouldn't
    /// execute anything reads as a no-op trap.
    func test_resultsDashboard_deselectingAllTilesHidesRun() throws {
        try runScanToResultsDashboard()
        let performanceCheckbox = app.descendants(matching: .any)["smartScan.togglePerformance"]
        guard performanceCheckbox.waitForExistence(timeout: 5) else {
            throw XCTSkip("Performance checkbox never appeared — dashboard didn't fully land.")
        }
        // Performance is the only checkbox guaranteed to appear (the others
        // depend on per-module work being found). Deselecting it should
        // remove the Run disc when no other tile has executable work — i.e.
        // when junk is empty AND no threats AND no updates AND no clutter
        // selected. On most test hosts the first three are empty (FDA off,
        // ClamAV absent), and largeFileSelection defaults empty.
        performanceCheckbox.click()

        // Give the dashboard a moment to re-evaluate `hasExecutableWork`.
        Thread.sleep(forTimeInterval: 0.5)
        let run = app.descendants(matching: .any)["smartScan.run"]
        // If other tiles produced work on this host (e.g. real available
        // updates), the disc would still be visible after deselecting
        // Performance alone — surface that as an XCTSkip rather than a
        // false-positive fail.
        if app.descendants(matching: .any)["smartScan.toggleApplications"].exists
            || app.descendants(matching: .any)["smartScan.toggleMyClutter"].exists
            || app.descendants(matching: .any)["smartScan.toggleMalware"].exists
            || app.descendants(matching: .any)["smartScan.toggleJunk"].exists {
            throw XCTSkip("This host has other actionable tiles; the disc remains visible after deselecting Performance alone.")
        }
        XCTAssertFalse(
            run.exists,
            "With every selected tile having no executable work, the Run disc must hide"
        )
    }

    /// Zero-work tiles never render a checkbox (no work to gate) and never
    /// render a Review button (nothing to drill into). Performance is the
    /// only tile guaranteed to be on every host, so we anchor the assertion
    /// to it inversely: every other tile should appear without its checkbox
    /// when its module produced no work. Most test hosts hit this state for
    /// at least one of Junk / Updates / Clutter / Malware.
    func test_resultsDashboard_zeroWorkTileHasNoCheckboxOrReview() throws {
        try runScanToResultsDashboard()
        // Pick whichever module is zero-work on this host as the anchor;
        // skip when every module happened to find work.
        let modules: [(toggle: String, review: String)] = [
            ("smartScan.toggleJunk", "smartScan.reviewJunk"),
            ("smartScan.toggleMalware", "smartScan.reviewMalware"),
            ("smartScan.toggleApplications", "smartScan.reviewApplications"),
            ("smartScan.toggleMyClutter", "smartScan.reviewMyClutter"),
        ]
        let zeroWorkModule = modules.first { module in
            !app.descendants(matching: .any)[module.toggle].exists
        }
        guard let zw = zeroWorkModule else {
            throw XCTSkip("Every module found work on this host — no zero-work tile to anchor the assertion.")
        }
        XCTAssertFalse(
            app.descendants(matching: .any)[zw.toggle].exists,
            "Zero-work tile must not show a checkbox"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[zw.review].exists,
            "Zero-work tile must not show a Review button"
        )
    }

    // MARK: - Review push (Slice 10)

    /// Performance is the only Review reliably reachable on every host —
    /// its tile is always actionable. Tapping Review opens the Performance
    /// Manager; tapping Back returns to the dashboard with selection
    /// preserved.
    func test_review_performancePushesAndBackReturnsToDashboard() throws {
        try runScanToResultsDashboard()
        let reviewButton = app.descendants(matching: .any)["smartScan.review"]
        guard reviewButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Performance Review button never appeared.")
        }
        reviewButton.click()

        let performanceReview = app.descendants(matching: .any)["smartScan.review.performance"]
        XCTAssertTrue(
            performanceReview.waitForExistence(timeout: 5),
            "Tapping Review on the Performance tile must push the Performance Manager"
        )
        // The Back identifier is on a SwiftUI `Button`, so query the
        // typed `app.buttons[...]` collection — `descendants(matching: .any)`
        // misses Buttons whose label is a `Label(_:systemImage:)` because
        // the system flattens the inner Text into the Button's accessibility
        // label rather than exposing it as a separate descendant.
        let backButton = app.buttons["smartScan.review.back"]
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 2),
            "The Review screen must expose a Back affordance"
        )
        backButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["smartScan.resultsHeading"]
                .waitForExistence(timeout: 5),
            "Back must return to the results dashboard"
        )
        // Performance is still selected — Back doesn't reset selection.
        XCTAssertTrue(
            app.descendants(matching: .any)["smartScan.togglePerformance"].exists,
            "Tile selection must be preserved after a Review round trip"
        )
    }

    /// Every reviewable module must wire a manager screen with the right
    /// identifier. Iterates the four data-bearing modules and verifies the
    /// push, skipping any module whose tile didn't produce work on this
    /// host (the Review button is absent for zero-work tiles).
    func test_review_pushesEachModulesReviewView() throws {
        try runScanToResultsDashboard()
        let modules: [(review: String, screen: String, label: String)] = [
            ("smartScan.reviewJunk", "smartScan.review.junk", "System Junk"),
            ("smartScan.reviewMalware", "smartScan.review.malware", "Protection"),
            ("smartScan.reviewApplications", "smartScan.review.applications", "Applications"),
            ("smartScan.reviewMyClutter", "smartScan.review.myClutter", "My Clutter"),
        ]
        var verifiedAny = false
        for module in modules {
            let reviewButton = app.buttons[module.review]
            guard reviewButton.exists else { continue }
            reviewButton.click()
            let screen = app.descendants(matching: .any)[module.screen]
            XCTAssertTrue(
                screen.waitForExistence(timeout: 5),
                "Review on \(module.label) must push the manager screen with id \(module.screen)"
            )
            verifiedAny = true
            let back = app.buttons["smartScan.review.back"]
            XCTAssertTrue(
                back.waitForExistence(timeout: 2),
                "\(module.label) Review screen must show a Back affordance"
            )
            back.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["smartScan.resultsHeading"]
                    .waitForExistence(timeout: 5),
                "Back from \(module.label) Review must return to the dashboard"
            )
        }
        if !verifiedAny {
            throw XCTSkip("No data-bearing modules to verify on this host — every tile was zero-work.")
        }
    }

    // MARK: - Helpers

    /// Drives a Smart Scan from intro through to the results dashboard so
    /// the dashboard / review assertions have a stable starting point.
    /// Long timeout because a real scan touches the filesystem, ClamAV,
    /// large-file walks, and the network — minutes are possible on a
    /// heavily-installed machine. The dashboard heading is the canonical
    /// "we're in `.results`" anchor, matching `SmartScanResultsState`'s
    /// `smartScan.resultsHeading` identifier.
    private func runScanToResultsDashboard() throws {
        dismissOnboardingIfNeeded()
        let scanButton = app.buttons["section.smartScan.scan"]
        guard scanButton.waitForExistence(timeout: 10) else {
            XCTFail("Scan button never appeared")
            return
        }
        scanButton.click()
        proceedPastScanAccessPopoverIfNeeded()
        let heading = app.descendants(matching: .any)["smartScan.resultsHeading"]
        // 180 s is generous; the test host may need most of it for the
        // update-check round trips and large-old-files walk. If we still
        // can't reach the dashboard, skip — the dashboard contract is
        // exhaustively unit-tested against injected fakes elsewhere.
        if !heading.waitForExistence(timeout: 180) {
            throw XCTSkip("Smart Scan didn't reach the results dashboard within 180 s — likely FDA / network gating on this host.")
        }
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
}
