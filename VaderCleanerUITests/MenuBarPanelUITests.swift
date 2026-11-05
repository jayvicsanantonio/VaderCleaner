// MenuBarPanelUITests.swift
// End-to-end coverage for the menu bar panel: clicking the status item opens the verdict, the readings, and the one button, and a reading deep-links into its section.

import XCTest

/// Drives the real status item and panel. Nothing here triggers a scan or a
/// purge: the reading exercised opens Cleanup, which waits for the user.
@MainActor
final class MenuBarPanelUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the first-run flow so it can't cover the main window the
        // reading opens.
        app.launchArguments = ["-welcome.hasCompleted", "YES", "-welcome.hasSeenScanHint", "YES"]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func openPanel() throws {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "VaderCleaner's status item should be in the menu bar")
        statusItem.click()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The panel opens with its verdict, the three readings, and its one
    /// button.
    func test_panel_showsVerdictReadingsAndOneButton() throws {
        try openPanel()

        XCTAssertTrue(element("menuBar.verdict").waitForExistence(timeout: 5))
        for reading in ["storage", "memory", "cpu"] {
            XCTAssertTrue(element("menuBar.reading.\(reading)").exists, "Expected the \(reading) reading")
        }
        XCTAssertTrue(element("menuBar.primaryAction").exists)
    }

    /// A reading opens the main window on the section that owns it.
    func test_reading_opensItsSection() throws {
        try openPanel()

        let storage = element("menuBar.reading.storage")
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        storage.click()

        let railRow = app.buttons["sidebar.systemJunk"].firstMatch
        XCTAssertTrue(railRow.waitForExistence(timeout: 5), "The main window should open")
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: railRow)
        wait(for: [selected], timeout: 5)
    }
}
