// SmartScanUITests.swift
// End-to-end UI test for Smart Scan — asserts the default landing section renders its idle Scan screen, exercising the App → ContentView → SmartScanView wiring against the real app process.

import XCTest

/// We never trigger an actual Smart Scan here — it walks the entire home
/// directory (System Junk scan) and runs `clamscan` for tens of seconds,
/// which would make the test slow and flaky, and there is no mock mode. The
/// scan / aggregation / clean contracts are covered exhaustively by
/// `SmartScanViewModelTests` against injected fakes. This test only proves the
/// section renders without crashing — which the unit tests cannot — following
/// the same pattern `MalwareUITests` uses for the same reason.
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

    func test_smartScanIsDefaultLanding_revealsIdleScanScreen() throws {
        dismissOnboardingIfNeeded()

        // Smart Scan is the default selected section, so its idle Scan button
        // should be present without any navigation.
        let scanButton = app.buttons["smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Expected the Smart Scan idle screen to be the default landing view"
        )
    }

    func test_navigateToSmartScan_revealsIdleScanScreen() throws {
        dismissOnboardingIfNeeded()

        // Navigate away and back to prove the sidebar → view wiring works
        // regardless of the default selection.
        // The sidebar is an icon-only rail, so rows expose no visible text —
        // locate them by their stable accessibility identifier instead.
        let otherRow = app.outlines.descendants(matching: .any)["sidebar.healthMonitor"].firstMatch
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5),
                      "Expected Health Monitor row in sidebar")
        otherRow.click()

        let smartScanRow = app.outlines.descendants(matching: .any)["sidebar.smartScan"].firstMatch
        XCTAssertTrue(smartScanRow.waitForExistence(timeout: 5),
                      "Expected Smart Scan row in sidebar")
        smartScanRow.click()

        let scanButton = app.buttons["smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Expected Smart Scan to render its idle Scan screen"
        )
    }

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }
}
