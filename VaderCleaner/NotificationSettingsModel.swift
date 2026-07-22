// NotificationSettingsModel.swift
// Backs the permission row on the Notifications settings tab — live authorization status, the one-shot system prompt, and the test banner.

import Foundation
import UserNotifications
import Observation

/// Drives the permission row at the top of the Notifications pane.
///
/// The pane's toggles are meaningless if macOS isn't letting the app through,
/// and `UNUserNotificationCenter.add` fails silently in that case — so the
/// status is read back here and shown, rather than assumed.
///
/// The status read and the permission request are injected so tests never touch
/// the real permission system, which would block on a clean machine.
@MainActor
@Observable
final class NotificationSettingsModel {

    typealias StatusReader = @MainActor () async -> UNAuthorizationStatus
    typealias PermissionRequester = @MainActor () async -> Void

    /// Starts pessimistic: the row renders before the first async read lands,
    /// and "not yet allowed" is the honest assumption until proven otherwise.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let dispatcher: NotificationDispatching
    @ObservationIgnored private let statusReader: StatusReader
    @ObservationIgnored private let permissionRequester: PermissionRequester

    init(
        dispatcher: NotificationDispatching,
        statusReader: @escaping StatusReader = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        permissionRequester: @escaping PermissionRequester
    ) {
        self.dispatcher = dispatcher
        self.statusReader = statusReader
        self.permissionRequester = permissionRequester
    }

    /// Re-reads the system's decision. Called when the pane appears and again
    /// when the app is reactivated, so changing it in System Settings shows up
    /// without a relaunch.
    func refresh() async {
        authorizationStatus = await statusReader()
    }

    /// Raises the system prompt, but only while that can still do something.
    /// After the user has answered once, `requestAuthorization` returns
    /// immediately without showing anything — the view sends them to System
    /// Settings in that case instead.
    func requestPermission() async {
        guard NotificationAccessStatus.canRequestPermission(for: authorizationStatus) else { return }
        await permissionRequester()
        await refresh()
    }

    /// Sends the sample banner. Deliberately ungated — its whole purpose is to
    /// show the user whether notifications actually arrive.
    func sendTest() {
        dispatcher.sendTestNotification()
    }
}
