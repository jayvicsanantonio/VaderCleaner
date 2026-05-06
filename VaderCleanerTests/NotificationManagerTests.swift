// NotificationManagerTests.swift
// Tests that NotificationManager constructs correctly-shaped notification content and that requestPermission returns.

import XCTest
import UserNotifications
@testable import VaderCleaner

@MainActor
final class NotificationManagerTests: XCTestCase {

    // MARK: - requestPermission

    /// Smoke test: `requestPermission()` must complete without throwing and
    /// without hanging. The unit-test bundle is loaded into the host app, so
    /// `UNUserNotificationCenter.current()` resolves to the app's center —
    /// `requestAuthorization` returns the cached state immediately when
    /// authorization has already been answered, and prompts the user otherwise.
    /// Either way, the call must not throw or block past the test timeout.
    func test_requestPermission_completesWithoutError() async {
        let manager = NotificationManager()
        await manager.requestPermission()
        // No assertion needed: completing the await without crashing satisfies
        // the contract. The XCTest timeout catches a hang.
    }

    // MARK: - Content shape

    /// The malware notification must surface the threat name in the body so the
    /// banner is actionable at a glance, and a recognisable title so the user
    /// can identify the alert from the macOS Notification Center summary.
    func test_malwareDetected_buildsContentWithThreatName() {
        let content = NotificationManager.makeMalwareDetectedContent(threatName: "Eicar-Test-Signature")
        XCTAssertTrue(content.title.contains("Malware"))
        XCTAssertTrue(content.body.contains("Eicar-Test-Signature"))
    }

    /// Low-disk notification embeds the free percentage so the user sees the
    /// severity without opening the app. The percentage is rounded to whole
    /// percent for readability.
    func test_lowDisk_buildsContentWithPercent() {
        let content = NotificationManager.makeLowDiskContent(freePercent: 7.4)
        XCTAssertTrue(content.title.lowercased().contains("disk"))
        XCTAssertTrue(content.body.contains("7%") || content.body.contains("7.4"))
    }

    /// High-RAM notification surfaces the pressure level string verbatim so a
    /// future tweak to `MemoryPressureLevel` labels (e.g. "Fair" → "Warning")
    /// doesn't require touching the manager.
    func test_highRAM_buildsContentWithPressureLevel() {
        let content = NotificationManager.makeHighRAMContent(pressureLevel: "Critical")
        XCTAssertTrue(content.title.lowercased().contains("memory") ||
                      content.title.lowercased().contains("ram"))
        XCTAssertTrue(content.body.contains("Critical"))
    }

    /// Large-files notification surfaces both the count and a human-readable
    /// total size — the pair is what makes the banner worth tapping.
    func test_largeFilesFound_buildsContentWithCountAndSize() {
        let content = NotificationManager.makeLargeFilesFoundContent(count: 42, totalSize: 1_500_000_000)
        XCTAssertTrue(content.body.contains("42"))
        // ByteCountFormatter produces "1.5 GB" or "1,5 GB" depending on locale;
        // assert the GB unit so the test isn't locale-fragile.
        XCTAssertTrue(content.body.contains("GB") || content.body.contains("MB"))
    }
}
