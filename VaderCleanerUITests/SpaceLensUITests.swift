// SpaceLensUITests.swift
// End-to-end UI test for Space Lens — navigates to the section, taps the floating Scan on the unified intro, and waits for either the in-progress scan or the post-scan treemap, asserting that the wiring between sidebar selection, view-model, and view reaches the user's home directory.

import XCTest

/// We do not assert on individual treemap tiles here. The home directory
/// scanned by the test machine is whatever the CI / developer runner
/// happens to have, so the only stable invariant is that the section
/// loads and the scan reaches a recognizable state. Tile rendering is
/// covered by `TreemapLayoutTests` against synthetic fixtures.
final class SpaceLensUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Persist the Space Lens view mode to a throwaway UserDefaults suite so
        // the toggle test doesn't leak the last-selected mode into the real
        // app preference (or couple test runs through shared state).
        app.launchEnvironment["UITEST_DEFAULTS_SUITE"] = "VaderCleanerUITests.SpaceLens.\(UUID().uuidString)"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    /// Sidebar → Space Lens must reach either the in-progress scanning
    /// indicator or the loaded treemap (or, on a permission-denied home
    /// directory, the error banner). Any of these is evidence that the
    /// view-model is alive and the scan kicked off — anything else is a
    /// wiring regression.
    func test_navigateToSpaceLens_scan_revealsScanningOrTreemap() throws {
        dismissOnboardingIfNeeded()
        navigateToSpaceLensAndScan()

        // After Scan we expect either the scanning indicator or — on tiny home
        // folders / fast machines — the treemap to land before our timeout.
        // The error banner is accepted as well: a CI runner without
        // home-folder access should still surface a recognizable state, not
        // hang on a blank canvas.
        let appeared = waitForAnySpaceLensState(timeout: 30)
        XCTAssertTrue(appeared,
                      "Expected to land on a recognizable Space Lens state after selection")
    }

    /// Once results render, the treemap/sunburst toggle must switch the
    /// visualization. We don't assert on specific arcs or tiles — the host's
    /// home directory is whatever the runner happens to have — only that
    /// tapping each toggle reveals that mode's view (or the shared empty
    /// placeholder, on a folder with no displayable children). Both prove the
    /// mode switch is wired through `SpaceLensViewModeStore`.
    func test_navigateToSpaceLens_toggleSwitchesBetweenTreemapAndSunburst() throws {
        dismissOnboardingIfNeeded()
        navigateToSpaceLensAndScan()

        // The toggle only exists in the ready state. A permission-restricted or
        // perpetually-scanning host can't exercise this path, so skip rather
        // than fail — the toggle's wiring is what's under test, not the host's
        // ability to finish a home-directory scan.
        let sunburstToggle = app.buttons["space-lens.viewMode.sunburst"]
        guard sunburstToggle.waitForExistence(timeout: 30) else {
            throw XCTSkip("Space Lens did not reach the ready state on this host; the view-mode toggle only appears once results render.")
        }
        let treemapToggle = app.buttons["space-lens.viewMode.treemap"]
        XCTAssertTrue(treemapToggle.exists, "Both view-mode toggle buttons should be present")

        sunburstToggle.click()
        XCTAssertTrue(waitForSpaceLensState(["space-lens.sunburst", "space-lens.empty"], timeout: 5),
                      "Tapping Sunburst should reveal the sunburst (or the empty placeholder)")

        treemapToggle.click()
        XCTAssertTrue(waitForSpaceLensState(["space-lens.treemap", "space-lens.empty"], timeout: 5),
                      "Tapping Treemap should reveal the treemap (or the empty placeholder)")
    }

    // MARK: - Helpers

    /// Drive the sidebar → Space Lens → floating Scan flow shared by the tests.
    /// Leaves the app in whatever post-Scan state the host's home directory
    /// produces (scanning / ready / empty / error).
    private func navigateToSpaceLensAndScan() {
        let sidebarRow = app.buttons["sidebar.spaceLens"].firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5),
                      "Expected Space Lens row in sidebar")
        sidebarRow.click()

        // Space Lens lands on the unified intro first; tapping the floating
        // Scan kicks off the walk that previously ran automatically on appear.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5),
                      "Expected the unified intro screen for Space Lens")
        // The per-section identifier proves it is *Space Lens's* intro, not
        // merely "an intro" — the "right title" contract.
        let spaceLensIntro = app.descendants(matching: .any)["section.intro.spacelens"]
        XCTAssertTrue(spaceLensIntro.waitForExistence(timeout: 5),
                      "Expected the Space Lens-specific intro identifier")
        let floatingScan = app.buttons["section.spaceLens.scan"]
        XCTAssertTrue(floatingScan.waitForExistence(timeout: 5),
                      "Expected the floating Scan button on the Space Lens intro")
        floatingScan.click()
        proceedPastScanAccessPopoverIfNeeded()
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

    private func waitForAnySpaceLensState(timeout: TimeInterval) -> Bool {
        waitForSpaceLensState([
            "space-lens.scanning",
            "space-lens.treemap",
            "space-lens.sunburst",
            "space-lens.error",
            "space-lens.empty"
        ], timeout: timeout)
    }

    /// Wait for any of the given accessibility identifiers to appear as a
    /// container group. Each Space Lens state (treemap, sunburst, empty, …)
    /// marks its root with `accessibilityElement(children: .contain)`, so they
    /// surface as groups.
    private func waitForSpaceLensState(_ identifiers: [String], timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "identifier IN %@", identifiers)
        return app.groups.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
