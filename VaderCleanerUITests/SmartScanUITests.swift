// SmartScanUITests.swift
// End-to-end UI test for Smart Scan — asserts the default landing section renders the unified intro screen and its floating Scan button, exercising the App → ContentView → SectionIntroView wiring against the real app process.

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

    func test_smartScanIsDefaultLanding_revealsIntroScreen() throws {
        dismissOnboardingIfNeeded()

        // Smart Scan is the default selected section, so the unified intro and
        // its floating Scan button should be present without any navigation.
        let intro = app.descendants(matching: .any)["section.intro"]
        XCTAssertTrue(
            intro.waitForExistence(timeout: 10),
            "Expected the Smart Scan intro screen to be the default landing view"
        )
        let scanButton = app.buttons["section.smartScan.scan"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 5),
            "Expected the floating Scan button on the Smart Scan intro"
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

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }
}
