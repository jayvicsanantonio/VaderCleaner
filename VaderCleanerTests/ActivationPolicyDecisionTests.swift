// ActivationPolicyDecisionTests.swift
// Tests the pure activation-policy rule that guards against leaving the user with no way to reopen the app.

import Testing
import AppKit
@testable import VaderCleaner
@testable import VaderCleanerCore

@Suite
struct ActivationPolicyDecisionTests {

    // MARK: - Window open ⇒ always .regular

    @Test
    func windowOpen_menuBarShown_isRegular() {
        #expect(
            ActivationPolicyDecision.policy(hasTitledWindow: true, menuBarShown: true) == .regular
        )
    }

    @Test
    func windowOpen_menuBarHidden_isRegular() {
        // Asserted explicitly so the function isn't accidentally indifferent
        // to `hasTitledWindow` — both branches must be exercised.
        #expect(
            ActivationPolicyDecision.policy(hasTitledWindow: true, menuBarShown: false) == .regular
        )
    }

    // MARK: - No window ⇒ depends on menu bar

    @Test
    func noWindow_menuBarShown_isAccessory() {
        // Menu bar icon is the entry point; the Dock icon can hide.
        #expect(
            ActivationPolicyDecision.policy(hasTitledWindow: false, menuBarShown: true) == .accessory
        )
    }

    @Test
    func noWindow_menuBarHidden_isRegular() {
        // Otherwise the user has no way to reopen the app.
        #expect(
            ActivationPolicyDecision.policy(hasTitledWindow: false, menuBarShown: false) == .regular
        )
    }
}
