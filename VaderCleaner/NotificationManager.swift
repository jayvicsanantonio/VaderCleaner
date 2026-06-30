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

    private let center: UNUserNotificationCenter
    private let authorizationRequester: AuthorizationRequester
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
        authorizationRequester: AuthorizationRequester? = nil
    ) {
        self.center = center
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
        deliver(content: Self.makeLowDiskContent(freeBytes: freeBytes))
    }

    func sendHighRAMNotification(pressureLevel: String) {
        deliver(content: Self.makeHighRAMContent(pressureLevel: pressureLevel))
    }

    func sendMalwareDetectedNotification(threatName: String) {
        deliver(content: Self.makeMalwareDetectedContent(threatName: threatName))
    }

    func sendLargeFilesFoundNotification(count: Int, totalSize: Int64) {
        deliver(content: Self.makeLargeFilesFoundContent(count: count,
                                                         totalSize: totalSize))
    }

    func sendTrashSizeNotification(sizeBytes: Int64) {
        deliver(content: Self.makeTrashSizeContent(sizeBytes: sizeBytes))
    }

    func sendDeviceBatteryLowNotification(deviceName: String, percent: Int) {
        deliver(content: Self.makeDeviceBatteryLowContent(deviceName: deviceName, percent: percent))
    }

    func sendDriveConnectedNotification(volumeName: String) {
        deliver(content: Self.makeDriveConnectedContent(volumeName: volumeName))
    }

    func sendOverfilledDriveNotification(volumeName: String, freeBytes: Int64, totalBytes: Int64) {
        deliver(content: Self.makeOverfilledDriveContent(volumeName: volumeName, freeBytes: freeBytes, totalBytes: totalBytes))
    }

    func sendAppTrashedNotification(appName: String) {
        deliver(content: Self.makeAppTrashedContent(appName: appName))
    }

    func sendHungAppNotification(appName: String) {
        deliver(content: Self.makeHungAppContent(appName: appName))
    }

    func sendScanFinishedNotification(scanName: String) {
        deliver(content: Self.makeScanFinishedContent(scanName: scanName))
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

    static func makeLowDiskContent(freeBytes: Int64) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Low Disk Space"
        // Reads in the same Finder-style units the Notifications picker offers
        // ("Less than 10 GB"), so the banner and the setting speak the same way.
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        content.body = "Only \(free) of disk space is free. Consider cleaning system junk."
        content.sound = .default
        return content
    }

    static func makeHighRAMContent(pressureLevel: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "High Memory Pressure"
        content.body = "Memory pressure is \(pressureLevel). Closing some apps may help."
        content.sound = .default
        return content
    }

    static func makeMalwareDetectedContent(threatName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Malware Detected"
        content.body = "VaderCleaner found \(threatName). Open the Protection section to review."
        content.sound = .default
        return content
    }

    static func makeLargeFilesFoundContent(count: Int, totalSize: Int64) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Large Files Found"
        let formattedSize = byteCountFormatter.string(fromByteCount: totalSize)
        content.body = "Found \(count) large or old files totaling \(formattedSize)."
        content.sound = .default
        return content
    }

    static func makeSmartCareReminderContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time for Smart Care"
        content.body = "Run a Smart Scan to keep your Mac clean, fast, and protected."
        content.sound = .default
        return content
    }

    static func makeTrashSizeContent(sizeBytes: Int64) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Trash Is Filling Up"
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        content.body = "Your Trash holds \(size). Empty it to reclaim the space."
        content.sound = .default
        return content
    }

    static func makeDeviceBatteryLowContent(deviceName: String, percent: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Device Battery Low"
        content.body = "\(deviceName) is at \(percent)%. Consider charging it soon."
        content.sound = .default
        return content
    }

    static func makeDriveConnectedContent(volumeName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Drive Connected"
        content.body = "\(volumeName) was mounted. Scan it with Space Lens to see what's using the space."
        content.sound = .default
        return content
    }

    static func makeOverfilledDriveContent(volumeName: String, freeBytes: Int64, totalBytes: Int64) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "External Drive Almost Full"
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        content.body = "\(volumeName) has only \(free) free. Clean it up to make room."
        content.sound = .default
        return content
    }

    static func makeAppTrashedContent(appName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Uninstall \(appName) Completely?"
        content.body = "You moved \(appName) to the Trash. Open Applications to remove its leftover files too."
        content.sound = .default
        return content
    }

    static func makeHungAppContent(appName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(appName) Is Not Responding"
        content.body = "\(appName) stopped responding. You can force quit it from the menu bar."
        content.sound = .default
        return content
    }

    static func makeScanFinishedContent(scanName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Scan Complete"
        content.body = "Your \(scanName) scan has finished. Open VaderCleaner to review the results."
        content.sound = .default
        return content
    }
}
