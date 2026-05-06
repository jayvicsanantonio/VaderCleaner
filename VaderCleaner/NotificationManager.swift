// NotificationManager.swift
// User-facing notification dispatcher — wraps UNUserNotificationCenter and exposes pure content builders for tests.

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
    func sendLowDiskNotification(freePercent: Double)
    func sendHighRAMNotification(pressureLevel: String)
    func sendMalwareDetectedNotification(threatName: String)
    func sendLargeFilesFoundNotification(count: Int, totalSize: Int64)
}

/// Production `NotificationDispatching` backed by
/// `UNUserNotificationCenter.current()`.
///
/// The four `send…` methods funnel through `make…Content(…)` static helpers so
/// the content shape (title, body, sound) can be unit-tested without
/// scheduling a real notification request — `UNUserNotificationCenter.add`
/// requires an authorized notification entitlement and a running app, neither
/// of which a unit test bundle reliably has.
@MainActor
final class NotificationManager: NotificationDispatching {

    private let center: UNUserNotificationCenter
    private let log = OSLog(subsystem: "com.personal.VaderCleaner",
                            category: "NotificationManager")

    /// `UNUserNotificationCenter.current()` is a singleton tied to the host
    /// app's bundle identifier; it is always the right instance in production.
    /// Exposed for parity with other ObservableObjects' init signatures, but
    /// production callers use the default.
    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Permission

    /// Asks the user (once, then cached by the system) for permission to
    /// display alerts and play sounds. Errors are logged and swallowed: a
    /// transient denial during launch must not crash the app, and the threshold
    /// monitor will still try to dispatch — `UNUserNotificationCenter.add`
    /// silently no-ops when authorization is missing, which is fine.
    func requestPermission() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            os_log("requestAuthorization failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Dispatch entry points

    func sendLowDiskNotification(freePercent: Double) {
        deliver(content: Self.makeLowDiskContent(freePercent: freePercent))
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

    static func makeLowDiskContent(freePercent: Double) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Low Disk Space"
        // Round to whole percent so the banner reads cleanly. The threshold
        // setting is itself an integer-feeling slider in Preferences, so a
        // sub-percent reading would look out of place next to it.
        let rounded = Int(freePercent.rounded())
        content.body = "Only \(rounded)% of disk space is free. Consider cleaning system junk."
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
        content.body = "VaderCleaner found \(threatName). Open the Malware Removal section to review."
        content.sound = .default
        return content
    }

    static func makeLargeFilesFoundContent(count: Int, totalSize: Int64) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Large Files Found"
        let formattedSize = ByteCountFormatter.string(
            fromByteCount: totalSize,
            countStyle: .file
        )
        content.body = "Found \(count) large or old files totaling \(formattedSize)."
        content.sound = .default
        return content
    }
}
