// MenuBarPanelUITests.swift
// End-to-end coverage for the menu bar panel: clicking the status item opens the header, attention area, readings, and shortcuts, and a shortcut deep-links into its section.

import XCTest

/// Drives the real status item and panel. Nothing here triggers a scan or a
/// purge: the shortcut exercised opens Space Lens, which waits for the user.
@MainActor
final class MenuBarPanelUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the first-run flow so it can't cover the main window the
        // shortcut opens.
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

    /// The panel opens with its verdict header, an attention area (an issue,
    /// a suggestion, or the all-clear line), the four readings, and the four
    /// verb shortcuts.
    func test_panel_showsHeaderAttentionReadingsAndShortcuts() throws {
        try openPanel()

        XCTAssertTrue(element("menuBar.header").waitForExistence(timeout: 5))
        XCTAssertTrue(element("menuBar.attention").exists)
        for tile in ["storage", "memory", "cpu", "network"] {
            XCTAssertTrue(element("menuBar.tile.\(tile)").exists, "Expected the \(tile) reading")
        }
        for action in ["smartScan", "systemJunk", "applications", "spaceLens"] {
            XCTAssertTrue(element("menuBar.action.\(action)").exists, "Expected the \(action) shortcut")
        }
    }

    /// A shortcut opens the main window on its section.
    func test_shortcut_opensItsSection() throws {
        try openPanel()

        let spaceLens = element("menuBar.action.spaceLens")
        XCTAssertTrue(spaceLens.waitForExistence(timeout: 5))
        spaceLens.click()

        let railRow = app.buttons["sidebar.spaceLens"].firstMatch
        XCTAssertTrue(railRow.waitForExistence(timeout: 5), "The main window should open")
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: railRow)
        wait(for: [selected], timeout: 5)
    }
}
