// VaderCleanerUITests.swift
// UI test target entry point — end-to-end tests will be added in Prompt 27.

import XCTest

final class VaderCleanerUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func test_appLaunches() throws {
        // Verify the app launches without crashing.
        XCTAssertTrue(app.state == .runningForeground, "Expected app to be running in foreground")
    }
}
