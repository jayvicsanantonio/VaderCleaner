// ScanningPreferencesUITests.swift
// End-to-end coverage for the "Customize Smart Care" Scanning preferences tab — that the module and System Junk category checkboxes are reachable and writable against the real app process.

import XCTest

/// Exercises the Settings → Scanning tab. The selections persist to real
/// UserDefaults, so each test restores any control it flips.
final class ScanningPreferencesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// The Scanning tab must be reachable and expose the five module checkboxes.
    func test_scanningTab_exposesModuleCheckboxes() throws {
        dismissOnboardingIfNeeded()
        openPreferences()
        preferenceTab("Scanning").click()

        for module in ["systemJunk", "malware", "optimization", "applications", "myClutter"] {
            let checkbox = control("scanning.module.\(module)")
            XCTAssertTrue(
                checkbox.waitForExistence(timeout: 5),
                "Expected the \"\(module)\" module checkbox in the Scanning tab"
            )
        }
    }

    /// Toggling a module checkbox off must flip its value; restore it afterward.
    func test_scanningTab_toggleModule_flipsControl() throws {
        dismissOnboardingIfNeeded()
        openPreferences()
        preferenceTab("Scanning").click()

        let checkbox = control("scanning.module.applications")
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5),
                      "Expected the Applications module checkbox")

        let before = isOn(checkbox)
        checkbox.click()
        waitUntil(checkbox, isOn: !before)

        // Restore the original value so the test leaves no persisted side effect.
        checkbox.click()
        waitUntil(checkbox, isOn: before)
    }

    /// Expanding Cleanup reveals its System Junk category checkboxes, which are
    /// writable.
    func test_scanningTab_junkCategory_isWritable() throws {
        dismissOnboardingIfNeeded()
        openPreferences()
        preferenceTab("Scanning").click()

        let trash = control("scanning.junkCategory.trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 5),
                      "Expected the Trash category checkbox under Cleanup")

        let before = isOn(trash)
        trash.click()
        waitUntil(trash, isOn: !before)

        trash.click()
        waitUntil(trash, isOn: before)
    }

    // MARK: - Helpers

    private func dismissOnboardingIfNeeded() {
        let continueWithout = app.buttons["Continue Without Access"]
        if continueWithout.waitForExistence(timeout: 2) {
            continueWithout.click()
        }
    }

    private func openPreferences() {
        app.typeKey(",", modifierFlags: .command)
    }

    /// SwiftUI's Settings `TabView` renders tab items as buttons, radio buttons,
    /// or toolbar buttons depending on the macOS release — resolve whichever
    /// carries the label. Mirrors the resolver in `FinalPolishUITests`.
    private func preferenceTab(_ label: String) -> XCUIElement {
        let button = app.buttons[label]
        if button.exists { return button }
        let radio = app.radioButtons[label]
        if radio.exists { return radio }
        let toolbarButton = app.toolbars.buttons[label]
        if toolbarButton.exists { return toolbarButton }
        return button
    }

    /// A checkbox `Toggle` surfaces as either a checkBox or a switch depending on
    /// the macOS release — resolve whichever query holds the identifier.
    private func control(_ identifier: String) -> XCUIElement {
        let checkbox = app.checkBoxes[identifier]
        if checkbox.exists { return checkbox }
        let toggle = app.switches[identifier]
        if toggle.exists { return toggle }
        return checkbox
    }

    /// Normalizes the several shapes `XCUIElement.value` takes for a macOS
    /// checkbox/switch into a Bool.
    private func isOn(_ element: XCUIElement) -> Bool {
        switch element.value {
        case let n as NSNumber: return n.boolValue
        case let b as Bool:     return b
        case let s as String:   return s == "1"
        case let i as Int:      return i == 1
        default:                return false
        }
    }

    private func waitUntil(_ element: XCUIElement,
                           isOn expected: Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
        let poll = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.isOn(element) == expected },
            object: nil
        )
        poll.expectationDescription = "checkbox reached isOn == \(expected)"
        XCTAssertEqual(
            XCTWaiter.wait(for: [poll], timeout: 5), .completed,
            "Expected the checkbox to reach isOn == \(expected)",
            file: file, line: line
        )
    }
}
