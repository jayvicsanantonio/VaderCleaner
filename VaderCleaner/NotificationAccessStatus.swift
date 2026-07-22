// NotificationAccessStatus.swift
// Pure mapping from the system's notification authorization state to the permission row shown on the Notifications settings tab.

import Foundation
import UserNotifications

/// Turns the system's notification authorization into a row the user can act
/// on. Without this, a denied permission makes every toggle on the pane inert
/// while the app carries on as if they worked — `UNUserNotificationCenter.add`
/// silently no-ops when authorization is missing.
///
/// Reuses `AccessStatusDisplay` so the permission rows in Settings look and
/// read the same wherever they appear.
enum NotificationAccessStatus {

    static func display(for status: UNAuthorizationStatus) -> AccessStatusDisplay {
        switch status {
        case .authorized, .ephemeral:
            return AccessStatusDisplay(
                isHealthy: true,
                detail: String(
                    localized: "VaderCleaner can let you know when something needs you.",
                    comment: "Notifications settings: alerts are allowed."
                ),
                actionTitle: nil
            )
        case .provisional:
            // Provisional delivery works, it just lands quietly in Notification
            // Centre — reporting it as broken would be wrong.
            return AccessStatusDisplay(
                isHealthy: true,
                detail: String(
                    localized: "Alerts arrive quietly in Notification Centre, without a banner or sound.",
                    comment: "Notifications settings: provisional authorization."
                ),
                actionTitle: nil
            )
        case .denied:
            return AccessStatusDisplay(
                isHealthy: false,
                detail: String(
                    localized: "Alerts are turned off for VaderCleaner, so nothing below will reach you.",
                    comment: "Notifications settings: alerts are denied."
                ),
                actionTitle: String(
                    localized: "Open Settings…",
                    comment: "Notifications settings: button opening System Settings › Notifications."
                )
            )
        case .notDetermined:
            return AccessStatusDisplay(
                isHealthy: false,
                detail: String(
                    localized: "VaderCleaner hasn't been allowed to send alerts yet.",
                    comment: "Notifications settings: authorization not yet requested."
                ),
                actionTitle: String(
                    localized: "Allow…",
                    comment: "Notifications settings: button requesting notification permission."
                )
            )
        @unknown default:
            return AccessStatusDisplay(
                isHealthy: false,
                detail: String(
                    localized: "VaderCleaner can't tell whether it's allowed to send alerts.",
                    comment: "Notifications settings: unrecognised authorization state."
                ),
                actionTitle: String(
                    localized: "Open Settings…",
                    comment: "Notifications settings: button opening System Settings › Notifications."
                )
            )
        }
    }

    /// Whether asking the system can still raise the permission prompt. Once
    /// the user has answered, only System Settings can change the decision —
    /// calling `requestAuthorization` again returns immediately and would leave
    /// the button looking broken.
    static func canRequestPermission(for status: UNAuthorizationStatus) -> Bool {
        status == .notDetermined
    }

    /// Deep-link to System Settings › Notifications, where a denied decision
    /// can be reversed.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
}
