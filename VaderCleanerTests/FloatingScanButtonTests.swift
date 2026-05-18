// FloatingScanButtonTests.swift
// Pins the reusable FloatingScanButton contract: stored title/accent/accessibility identifier and that triggering it invokes the supplied action.

import XCTest
import SwiftUI
@testable import VaderCleaner

@MainActor
final class FloatingScanButtonTests: XCTestCase {

    func test_exposesPassedAccessibilityIdentifier() {
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.accessibilityIdentifier,
            "section.scan",
            "FloatingScanButton must surface the accessibility identifier it was given"
        )
    }

    func test_storesPassedTitle() {
        let button = FloatingScanButton(
            title: "Clean",
            accessibilityIdentifier: "section.clean",
            action: {}
        )

        XCTAssertEqual(button.title, "Clean")
    }

    func test_invokesActionOnTrigger() {
        var fired = false
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: { fired = true }
        )

        XCTAssertFalse(fired, "Action must not fire on construction")

        button.action()

        XCTAssertTrue(fired, "Triggering the button must invoke the supplied action")
    }

    func test_defaultAccentIsVaderCrimson() {
        // The default keeps existing SmartScan call sites visually unchanged
        // after the extraction — they pass no accent and must stay crimson.
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.accent,
            .vaderCrimson,
            "FloatingScanButton must default its tint to VaderTheme crimson"
        )
    }

    func test_customAccentIsStored() {
        let button = FloatingScanButton(
            title: "Scan",
            accent: .blue,
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.accent,
            .blue,
            "A caller-supplied accent must override the crimson default"
        )
    }
}
