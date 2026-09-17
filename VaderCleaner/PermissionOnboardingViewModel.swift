// PermissionOnboardingViewModel.swift
// View-model backing the FDA onboarding sheet — owns dismissal state and the System Settings deep-link.

import Foundation
import AppKit
import Observation

/// Drives `PermissionOnboardingView`. Holds the per-session dismissal flag and the URL
/// that opens the Full Disk Access pane in System Settings.
///
/// `systemSettingsURL` is exposed as a static constant so tests can assert the URL
/// string without having `openSystemSettings()` actually launch System Settings.
@MainActor
@Observable
final class PermissionOnboardingViewModel {

    /// Deep-link to System Settings → Privacy & Security → Full Disk Access.
    /// Uses the macOS 13+ identifier `com.apple.Settings.PrivacyAndSecurity.extension`,
    /// which lands directly on the Full Disk Access pane. The legacy
    /// `com.apple.preference.security` identifier still redirects but typically
    /// drops the user on the root Privacy pane and requires another click.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Settings.PrivacyAndSecurity.extension?Privacy_AllFiles"
    )!

    /// Set to `true` when the user chooses "Continue Without Access". Suppresses the
    /// sheet for the remainder of the session — feature views still surface their
    /// own inline Full Disk Access prompts where they need it.
    var isDismissed: Bool = false

    /// Set once the user has opened System Settings from this sheet, so the view
    /// can explain — only once it's relevant — why "Check Again" alone won't pick
    /// up a grant made while VaderCleaner was already running.
    private(set) var hasVisitedSystemSettings = false

    @ObservationIgnored private let openSystemSettingsAction: () -> Void

    init(openSystemSettings: @escaping () -> Void) {
        self.openSystemSettingsAction = openSystemSettings
    }

    /// Production wiring: the real System Settings deep-link.
    static func live() -> PermissionOnboardingViewModel {
        PermissionOnboardingViewModel(openSystemSettings: {
            NSWorkspace.shared.open(systemSettingsURL)
        })
    }

    func dismiss() {
        isDismissed = true
    }

    func openSystemSettings() {
        hasVisitedSystemSettings = true
        openSystemSettingsAction()
    }
}
