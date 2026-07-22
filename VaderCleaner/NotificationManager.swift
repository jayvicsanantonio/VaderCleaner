// NotificationManager.swift
// User-facing notification dispatcher — wraps UNUserNotificationCenter, presents banners while foregrounded, and exposes pure content builders for tests.

import Foundation
import UserNotifications
import os.log

/// Abstracts the four notification dispatch entry points plus the
/// permission-request flow so the threshold monitor (and any future feature
/// module) can be unit-tested with a stub instead of touching the real
/// `UNUserNotificationCenter`.
@MainActor
protocol NotificationDispatching: AnyObject {
    func requestPermission() async
    func sendLowDiskNotification(freeBytes: Int64)
    func sendHighRAMNotification(pressureLevel: String)
    func sendMalwareDetectedNotification(threatName: String)
    func sendLargeFilesFoundNotification(count: Int, totalSize: Int64)
    // Notifications pane parity.
    func sendTrashSizeNotification(sizeBytes: Int64)
    func sendDeviceBatteryLowNotification(deviceName: String, percent: Int)
    func sendDriveConnectedNotification(volumeName: String)
    func sendOverfilledDriveNotification(volumeName: String, freeBytes: Int64, totalBytes: Int64)
    func sendAppTrashedNotification(appName: String)
    func sendHungAppNotification(appName: String)
    func sendScanFinishedNotification(scanName: String)
    func sendAppUpdatesNotification(count: Int)
    func sendDefinitionsStaleNotification(daysSinceUpdate: Int)
    /// Sends the "does this work?" banner from Settings. Ungated by design.
    func sendTestNotification()
}

/// Production `NotificationDispatching` backed by
/// `UNUserNotificationCenter.current()`.
///
/// The four `send…` methods funnel through `make…Content(…)` static helpers so
/// the content shape (title, body, sound) can be unit-tested without
/// scheduling a real notification request — `UNUserNotificationCenter.add`
/// requires an authorized notification entitlement and a running app, neither
/// of which a unit test bundle reliably has.
///
/// ## Foreground presentation
///
/// `UNUserNotificationCenter` suppresses banners while the owning app is
/// frontmost unless a delegate opts in via
/// `userNotificationCenter(_:willPresent:withCompletionHandler:)`. Setting
/// `self` as the delegate and returning `[.banner, .sound]` keeps low-disk /
/// high-RAM alerts visible even while the user has the Health Monitor open —
/// which is precisely when those alerts are most actionable.
@MainActor
final class NotificationManager: NSObject, NotificationDispatching, UNUserNotificationCenterDelegate {

    /// Closure that performs the underlying `requestAuthorization` call.
    /// Production wires this through `UNUserNotificationCenter`. Tests inject
    /// a no-op so the test bundle never hits the real permission system —
    /// which would block in CI on a clean machine.
    typealias AuthorizationRequester = @MainActor () async throws -> Bool

    /// Reads the user's "play a sound" preference at dispatch time. A closure
    /// rather than a stored flag so flipping the toggle applies to the very
    /// next banner, and so the manager needs no reference to `PreferencesStore`.
    typealias SoundPreferenceReader = @MainActor () -> Bool

    private let center: UNUserNotificationCenter
    private let authorizationRequester: AuthorizationRequester
    private let soundEnabled: SoundPreferenceReader

    /// The live value of the sound preference — exposed so the behaviour is
    /// observable in tests without dispatching a real notification.
    var currentSoundEnabled: Bool { soundEnabled() }
    private let log = OSLog(subsystem: "com.personal.VaderCleaner",
                            category: "NotificationManager")

    /// Single shared formatter for byte → string conversion in the
    /// large-files notification body. `ByteCountFormatter` allocates internal
    /// state on each construction; reusing one instance avoids unnecessary
    /// churn even though the per-kind cooldown already throttles fire rate.
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// - Parameters:
    ///   - center: `UNUserNotificationCenter.current()` is the right
    ///     production instance; tests can pass a different instance only
    ///     incidentally — the meaningful seam is `authorizationRequester`.
    ///   - authorizationRequester: Override for the underlying authorization
    ///     call. Defaults to invoking
    ///     `center.requestAuthorization(options: [.alert, .sound])`. Tests
    ///     pass a closure that returns immediately so `requestPermission`
    ///     never blocks waiting for user input.
    init(
        center: UNUserNotificationCenter = .current(),
        authorizationRequester: AuthorizationRequester? = nil,
        soundEnabled: @escaping SoundPreferenceReader = { true }
    ) {
        self.center = center
        self.soundEnabled = soundEnabled
        // Capture `center` in the default requester closure so the seam still
        // routes through the supplied center instance when no override is
        // provided.
        self.authorizationRequester = authorizationRequester ?? { [center] in
            try await center.requestAuthorization(options: [.alert, .sound])
        }
        super.init()
        // The delegate property is `weak`, so the manager has to live for the
        // notifications to keep presenting. In production the App holds it as
        // a stored property; in tests the manager is held by the test method
        // and the post-test deallocation cleans up the weak ref harmlessly.
        center.delegate = self
    }

    // MARK: - Permission

    /// Asks the user (once, then cached by the system) for permission to
    /// display alerts and play sounds. Errors are logged and swallowed: a
    /// transient denial during launch must not crash the app, and the threshold
    /// monitor will still try to dispatch — `UNUserNotificationCenter.add`
    /// silently no-ops when authorization is missing, which is fine.
    func requestPermission() async {
        do {
            _ = try await authorizationRequester()
        } catch {
            os_log("requestAuthorization failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Tells the system to present the banner + sound even while VaderCleaner
    /// is the active app. Without this hook the user never sees an in-app
    /// banner for low-disk / high-RAM alerts — the most common moment to act
    /// on those alerts is precisely when the app is frontmost.
    ///
    /// Marked `nonisolated` because UNUserNotificationCenter delegate methods
    /// may be invoked from any thread. The body touches no instance state and
    /// just calls the completion handler synchronously, which is safe.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Dispatch entry points

    func sendLowDiskNotification(freeBytes: Int64) {
        deliver(content: Self.makeLowDiskContent(freeBytes: freeBytes, sound: soundEnabled()))
    }

    func sendHighRAMNotification(pressureLevel: String) {
        deliver(content: Self.makeHighRAMContent(pressureLevel: pressureLevel, sound: soundEnabled()))
    }

    func sendMalwareDetectedNotification(threatName: String) {
        deliver(content: Self.makeMalwareDetectedContent(threatName: threatName, sound: soundEnabled()))
    }

    func sendLargeFilesFoundNotification(count: Int, totalSize: Int64) {
        deliver(content: Self.makeLargeFilesFoundContent(count: count,
                                                         totalSize: totalSize,
                                                         sound: soundEnabled()))
    }

    func sendTrashSizeNotification(sizeBytes: Int64) {
        deliver(content: Self.makeTrashSizeContent(sizeBytes: sizeBytes, sound: soundEnabled()))
    }

    func sendDeviceBatteryLowNotification(deviceName: String, percent: Int) {
        deliver(content: Self.makeDeviceBatteryLowContent(deviceName: deviceName, percent: percent, sound: soundEnabled()))
    }

    func sendDriveConnectedNotification(volumeName: String) {
        deliver(content: Self.makeDriveConnectedContent(volumeName: volumeName, sound: soundEnabled()))
    }

    func sendOverfilledDriveNotification(volumeName: String, freeBytes: Int64, totalBytes: Int64) {
        deliver(content: Self.makeOverfilledDriveContent(volumeName: volumeName, freeBytes: freeBytes, totalBytes: totalBytes, sound: soundEnabled()))
    }

    func sendAppTrashedNotification(appName: String) {
        deliver(content: Self.makeAppTrashedContent(appName: appName, sound: soundEnabled()))
    }

    func sendHungAppNotification(appName: String) {
        deliver(content: Self.makeHungAppContent(appName: appName, sound: soundEnabled()))
    }

    func sendScanFinishedNotification(scanName: String) {
        deliver(content: Self.makeScanFinishedContent(scanName: scanName, sound: soundEnabled()))
    }

    func sendAppUpdatesNotification(count: Int) {
        deliver(content: Self.makeAppUpdatesContent(count: count, sound: soundEnabled()))
    }

    func sendDefinitionsStaleNotification(daysSinceUpdate: Int) {
        deliver(content: Self.makeDefinitionsStaleContent(daysSinceUpdate: daysSinceUpdate, sound: soundEnabled()))
    }

    /// Sends a banner the user asked for from Settings, so they can confirm
    /// notifications actually arrive. Deliberately not gated by any toggle —
    /// it exists precisely to test delivery.
    func sendTestNotification() {
        deliver(content: Self.makeTestContent(sound: soundEnabled()))
    }

    /// Schedules `content` for immediate delivery. A unique request identifier
    /// per call avoids collapsing into a still-displayed banner from a previous
    /// firing — the monitor's per-kind cooldown already prevents spam, and
    /// users expect each post-cooldown alert to be a fresh banner rather than
    /// a silent merge.
    private func deliver(content: UNNotificationContent) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { [log] error in
            if let error = error {
                os_log("UNUserNotificationCenter.add failed: %{public}@",
                       log: log, type: .error, error.localizedDescription)
            }
        }
    }

    // MARK: - Content builders (pure — unit-test surface)

    /// Builds a content object with the shared delivery settings. Every builder
    /// funnels through here so "sounds off" can never be forgotten on one
    /// banner — a `nil` sound is what makes the system present it quietly.
    private static func content(title: String, body: String, sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        return content
    }

    static func makeLowDiskContent(freeBytes: Int64, sound: Bool = true) -> UNMutableNotificationContent {
        // Reads in the same Finder-style units the Notifications picker offers
        // ("Less than 10 GB"), so the banner and the setting speak the same way.
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return content(
            title: "Your disk is getting full",
            body: "Only \(free) left. A quick clean-up will give your Mac room to breathe.",
            sound: sound
        )
    }

    static func makeHighRAMContent(pressureLevel: String, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Your Mac is low on memory",
            body: "Memory pressure is \(pressureLevel). Closing a few apps should help.",
            sound: sound
        )
    }

    static func makeMalwareDetectedContent(threatName: String, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Malware found",
            body: "VaderCleaner found \(threatName). Open Protection to deal with it.",
            sound: sound
        )
    }

    static func makeLargeFilesFoundContent(count: Int, totalSize: Int64, sound: Bool = true) -> UNMutableNotificationContent {
        let formattedSize = byteCountFormatter.string(fromByteCount: totalSize)
        return content(
            title: "Large & forgotten files",
            body: "\(count) files are taking up \(formattedSize). Worth a look.",
            sound: sound
        )
    }

    static func makeSmartCareReminderContent(sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Time for a Smart Scan",
            body: "A quick check keeps your Mac clean, fast, and protected.",
            sound: sound
        )
    }

    static func makeTrashSizeContent(sizeBytes: Int64, sound: Bool = true) -> UNMutableNotificationContent {
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return content(
            title: "Your Trash is filling up",
            body: "It's holding \(size). Emptying it gives that space back.",
            sound: sound
        )
    }

    static func makeDeviceBatteryLowContent(deviceName: String, percent: Int, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "A connected device is low",
            body: "\(deviceName) is at \(percent)%. Worth charging it soon.",
            sound: sound
        )
    }

    static func makeDriveConnectedContent(volumeName: String, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "\(volumeName) is connected",
            body: "Space Lens can show you what's using room on it.",
            sound: sound
        )
    }

    static func makeOverfilledDriveContent(volumeName: String, freeBytes: Int64, totalBytes: Int64, sound: Bool = true) -> UNMutableNotificationContent {
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return content(
            title: "\(volumeName) is nearly full",
            body: "Only \(free) left on it. A clean-up will make room.",
            sound: sound
        )
    }

    static func makeAppTrashedContent(appName: String, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Remove \(appName) completely?",
            body: "You put it in the Trash, but its leftover files are still here. VaderCleaner can clear those too.",
            sound: sound
        )
    }

    static func makeHungAppContent(appName: String, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "\(appName) isn't responding",
            body: "You can force it to quit from the VaderCleaner menu bar icon.",
            sound: sound
        )
    }

    static func makeScanFinishedContent(scanName: String, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Your \(scanName) scan is done",
            body: "Open VaderCleaner to see what turned up.",
            sound: sound
        )
    }

    static func makeAppUpdatesContent(count: Int, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "App updates are ready",
            body: "\(count) of your apps have newer versions. Updates bring fixes and security improvements.",
            sound: sound
        )
    }

    static func makeDefinitionsStaleContent(daysSinceUpdate: Int, sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Malware definitions are out of date",
            body: "They were last refreshed \(daysSinceUpdate) days ago. Updating helps Protection catch the newest threats.",
            sound: sound
        )
    }

    /// The "does this work?" banner sent from Settings.
    static func makeTestContent(sound: Bool = true) -> UNMutableNotificationContent {
        content(
            title: "Notifications are working",
            body: "This is what a VaderCleaner alert looks like.",
            sound: sound
        )
    }
}
