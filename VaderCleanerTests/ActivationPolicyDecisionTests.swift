// ActivationPolicyDecisionTests.swift
// Tests the pure activation-policy rule that guards against leaving the user with no way to reopen the app.

import XCTest
import AppKit
@testable import VaderCleaner

final class ActivationPolicyDecisionTests: XCTestCase {

    // MARK: - Window open ⇒ always .regular

    func test_windowOpen_menuBarShown_isRegular() {
        XCTAssertEqual(
            ActivationPolicyDecision.policy(hasTitledWindow: true, menuBarShown: true),
            .regular
        )
    }

    func test_windowOpen_menuBarHidden_isRegular() {
        // Asserted explicitly so the function isn't accidentally indifferent
        // to `hasTitledWindow` — both branches must be exercised.
        XCTAssertEqual(
            ActivationPolicyDecision.policy(hasTitledWindow: true, menuBarShown: false),
            .regular
        )
    }

    // MARK: - No window ⇒ depends on menu bar

    func test_noWindow_menuBarShown_isAccessory() {
        // Menu bar icon is the entry point; the Dock icon can hide.
        XCTAssertEqual(
            ActivationPolicyDecision.policy(hasTitledWindow: false, menuBarShown: true),
            .accessory
        )
    }

    func test_noWindow_menuBarHidden_isRegular() {
        // Otherwise the user has no way to reopen the app.
        XCTAssertEqual(
            ActivationPolicyDecision.policy(hasTitledWindow: false, menuBarShown: false),
            .regular
        )
    }
}
