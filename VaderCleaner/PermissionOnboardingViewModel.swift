// PermissionOnboardingViewModel.swift
// View-model backing the FDA onboarding sheet — owns dismissal state and the System Settings deep-link.

import Foundation
import AppKit
import Combine

/// Drives `PermissionOnboardingView`. Holds the per-session dismissal flag and the URL
/// that opens the Full Disk Access pane in System Settings.
///
/// `systemSettingsURL` is exposed as a static constant so tests can assert the URL
/// string without having `openSystemSettings()` actually launch System Settings.
@MainActor
final class PermissionOnboardingViewModel: ObservableObject {

    /// Deep-link to System Settings → Privacy & Security → Full Disk Access.
    /// Uses the macOS 13+ identifier `com.apple.Settings.PrivacyAndSecurity.extension`,
    /// which lands directly on the Full Disk Access pane. The legacy
    /// `com.apple.preference.security` identifier still redirects but typically
    /// drops the user on the root Privacy pane and requires another click.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Settings.PrivacyAndSecurity.extension?Privacy_AllFiles"
    )!

    /// Set to `true` when the user chooses "Continue Without Access". Suppresses the
    /// sheet for the remainder of the session — feature views still surface inline
    /// FDA prompts where they need access (added in later prompts).
    @Published var isDismissed: Bool = false

    func dismiss() {
        isDismissed = true
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }
}
