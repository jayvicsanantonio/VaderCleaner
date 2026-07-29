// VaderCleanerUITests.swift
// UI test target entry point — end-to-end tests will be added in Prompt 27.

import XCTest

@MainActor
final class VaderCleanerUITests: XCTestCase {

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

    func test_appLaunches() throws {
        // Verify the app launches without crashing.
        XCTAssertTrue(app.state == .runningForeground, "Expected app to be running in foreground")
    }
}
