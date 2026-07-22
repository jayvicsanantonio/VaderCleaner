// ActivationPolicyDecision.swift
// Pure decision logic for NSApp.setActivationPolicy — keeps at least one entry point to the app available.

import AppKit

/// Decides which `NSApplication.ActivationPolicy` to apply given the current
/// app state. Pure so the rule can be asserted in tests without driving
/// `NSApp` or AppKit lifecycle events.
///
/// The contract this enforces: the user must always have at least one way to
/// reopen VaderCleaner. If both the main window is closed *and* the menu bar
/// extra is hidden, going `.accessory` would also drop the Dock icon, leaving
/// the user with no entry point. In that case the decision is `.regular` so
/// the Dock icon stays.
enum ActivationPolicyDecision {

    /// - Parameters:
    ///   - hasTitledWindow: Whether at least one titled `NSWindow` is currently
    ///     present. The main `Window` scene counts; the menu bar extra's
    ///     popover is borderless and does not.
    ///   - menuBarShown: Whether the user has the menu bar extra enabled (the
    ///     `showMenuBar` preference).
    ///   - keepDockIcon: Whether the user asked to keep the Dock icon
    ///     regardless of windows (the Dock/Both cases of `MenuBarPresence`).
    static func policy(
        hasTitledWindow: Bool,
        menuBarShown: Bool,
        keepDockIcon: Bool = false
    ) -> NSApplication.ActivationPolicy {
        // An explicit request for the Dock icon outranks everything else.
        if keepDockIcon {
            return .regular
        }
        if hasTitledWindow {
            // A titled window means the Dock icon is needed.
            return .regular
        }
        // No window open. The menu bar extra is the only remaining entry
        // point; if it's also hidden, fall back to `.regular` so the Dock
        // icon doesn't disappear.
        return menuBarShown ? .accessory : .regular
    }
}
