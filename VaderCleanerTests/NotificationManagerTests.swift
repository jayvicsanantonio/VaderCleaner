// NotificationManagerTests.swift
// Tests that NotificationManager constructs correctly-shaped notification content and that requestPermission returns.

import XCTest
import UserNotifications
@testable import VaderCleaner

@MainActor
final class NotificationManagerTests: XCTestCase {

    // MARK: - requestPermission

    /// Smoke test: `requestPermission()` must complete without throwing and
    /// without hanging. The injected requester closure stands in for
    /// `UNUserNotificationCenter.requestAuthorization`, which on a clean CI
    /// machine could otherwise block waiting for a user decision and time out
    /// the suite.
    func test_requestPermission_completesWithoutError() async {
        let manager = NotificationManager(authorizationRequester: { true })
        await manager.requestPermission()
        // No assertion needed: completing the await without crashing satisfies
        // the contract. The XCTest timeout catches a hang.
    }

    /// A throwing requester must be swallowed, not propagated — the spec says
    /// a transient denial during launch must not crash the app.
    func test_requestPermission_swallowsErrors() async {
        struct StubError: Error {}
        let manager = NotificationManager(authorizationRequester: { throw StubError() })
        await manager.requestPermission()
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

    /// Low-disk notification embeds the free space (Finder-style units) so the
    /// user sees the severity without opening the app.
    func test_lowDisk_buildsContentWithFreeSpace() {
        let content = NotificationManager.makeLowDiskContent(freeBytes: 8_000_000_000)
        XCTAssertTrue(content.title.lowercased().contains("disk"))
        XCTAssertTrue(content.body.contains("GB"))
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

    /// The app-updates banner leads with the count, since "how many" is what
    /// decides whether the user opens the app now or later.
    func test_appUpdates_buildsContentWithCount() {
        let content = NotificationManager.makeAppUpdatesContent(count: 7)
        XCTAssertTrue(content.body.contains("7"))
        XCTAssertFalse(content.title.isEmpty)
    }

    /// Stale definitions are only actionable if the banner says how stale, so
    /// the age has to reach the body.
    func test_definitionsStale_buildsContentWithAge() {
        let content = NotificationManager.makeDefinitionsStaleContent(daysSinceUpdate: 30)
        XCTAssertTrue(content.body.contains("30"))
        XCTAssertTrue(content.title.lowercased().contains("protection") ||
                      content.title.lowercased().contains("malware") ||
                      content.title.lowercased().contains("definition"))
    }

    // MARK: - Sound

    /// Every banner played an unconditional sound before the preference
    /// existed, so `sound: true` must stay the default behaviour.
    func test_content_carriesSoundByDefault() {
        XCTAssertNotNil(NotificationManager.makeLowDiskContent(freeBytes: 1).sound)
        XCTAssertNotNil(NotificationManager.makeScanFinishedContent(scanName: "Smart Scan").sound)
    }

    /// With sounds off the banner must still be delivered — silently. A `nil`
    /// sound is what makes `UNUserNotificationCenter` present it quietly.
    func test_content_omitsSoundWhenDisabled() {
        XCTAssertNil(NotificationManager.makeLowDiskContent(freeBytes: 1, sound: false).sound)
        XCTAssertNil(NotificationManager.makeHighRAMContent(pressureLevel: "Critical", sound: false).sound)
        XCTAssertNil(NotificationManager.makeMalwareDetectedContent(threatName: "X", sound: false).sound)
        XCTAssertNil(NotificationManager.makeAppUpdatesContent(count: 1, sound: false).sound)
        XCTAssertNil(NotificationManager.makeDefinitionsStaleContent(daysSinceUpdate: 1, sound: false).sound)
    }

    /// The manager reads the live preference through its injected closure, so
    /// flipping the toggle takes effect on the next banner without a relaunch.
    func test_manager_readsSoundPreferenceAtDispatchTime() {
        var soundsOn = true
        let manager = NotificationManager(
            authorizationRequester: { true },
            soundEnabled: { soundsOn }
        )
        XCTAssertTrue(manager.currentSoundEnabled)
        soundsOn = false
        XCTAssertFalse(manager.currentSoundEnabled)
    }

    // MARK: - Foreground presentation delegate

    /// Without this delegate hook, `UNUserNotificationCenter` suppresses
    /// banners while the app is foregrounded — exactly when the user is most
    /// likely to act on a low-disk or high-RAM alert. The completion handler
    /// must request both `.banner` and `.sound`.
    func test_willPresent_returnsBannerAndSound() {
        let manager = NotificationManager(authorizationRequester: { true })
        let center = UNUserNotificationCenter.current()
        // Build a `UNNotification` indirectly by invoking the delegate method
        // with a synthesized request — we only care that the completion is
        // called with the right options. The notification argument is unused
        // by our implementation, so passing a dummy is fine.
        let exp = expectation(description: "completion handler invoked")
        var received: UNNotificationPresentationOptions = []
        // The delegate method is `nonisolated` so calling it off the main
        // actor is permitted, but we're already on @MainActor here in the
        // test. Either is fine.
        manager.userNotificationCenter(
            center,
            willPresent: Self.makeDummyNotification(),
            withCompletionHandler: { options in
                received = options
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(received.contains(.banner))
        XCTAssertTrue(received.contains(.sound))
    }

    /// `UNNotification` has no public initializer; building one from a coded
    /// archive of a `UNNotificationRequest` is the standard workaround for
    /// tests that need to feed the delegate API. Failing to decode falls back
    /// to `XCTFail` so a future SDK change surfaces clearly.
    private static func makeDummyNotification() -> UNNotification {
        let request = UNNotificationRequest(
            identifier: "test",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(request, forKey: "request")
        archiver.encode(Date(), forKey: "date")
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else {
            XCTFail("Failed to construct NSKeyedUnarchiver")
            fatalError("unreachable")
        }
        unarchiver.requiresSecureCoding = false
        guard let notification = UNNotification(coder: unarchiver) else {
            XCTFail("UNNotification(coder:) returned nil — Apple SDK contract change")
            fatalError("unreachable")
        }
        return notification
    }
}
