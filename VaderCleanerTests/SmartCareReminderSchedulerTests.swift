// SmartCareReminderSchedulerTests.swift
// Verifies the Smart Care reminder schedules/cancels per the toggle and maps each cadence to the right calendar match.

import XCTest
import UserNotifications
@testable import VaderCleaner

@MainActor
final class SmartCareReminderSchedulerTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var scheduled: [UNNotificationRequest] = []
    private var cancelled: [[String]] = []

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.SmartCare.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        scheduled = []
        cancelled = []
    }

    private func makeScheduler() -> SmartCareReminderScheduler {
        SmartCareReminderScheduler(
            preferences: preferences,
            schedule: { [unowned self] in self.scheduled.append($0) },
            cancel: { [unowned self] in self.cancelled.append($0) }
        )
    }

    /// The reminder is built ahead of time and handed to the system, so it has
    /// to bake in the sound preference at schedule time — otherwise turning
    /// sounds off leaves this one banner still chiming.
    func test_update_honoursTheSoundPreference() {
        preferences.remindSmartCare = true
        preferences.notificationSoundsEnabled = false

        makeScheduler().update()

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertNil(scheduled.first?.content.sound)
    }

    func test_update_keepsTheSoundWhenSoundsAreOn() {
        preferences.remindSmartCare = true
        preferences.notificationSoundsEnabled = true

        makeScheduler().update()

        XCTAssertNotNil(scheduled.first?.content.sound)
    }

    func test_dateComponents_mapEachFrequency() {
        let daily = SmartCareReminderScheduler.dateComponents(for: .daily)
        XCTAssertNil(daily.weekday)
        XCTAssertNil(daily.day)
        XCTAssertEqual(daily.hour, 10)

        let weekly = SmartCareReminderScheduler.dateComponents(for: .weekly)
        XCTAssertEqual(weekly.weekday, 2)

        let monthly = SmartCareReminderScheduler.dateComponents(for: .monthly)
        XCTAssertEqual(monthly.day, 1)
    }

    func test_update_schedulesRepeatingReminderWhenOn() {
        preferences.remindSmartCare = true
        preferences.smartCareFrequency = .weekly
        let scheduler = makeScheduler()

        scheduler.update()

        // Always clears the prior request before scheduling the new one.
        XCTAssertEqual(cancelled, [[SmartCareReminderScheduler.reminderIdentifier]])
        XCTAssertEqual(scheduled.count, 1)
        let request = scheduled.first
        XCTAssertEqual(request?.identifier, SmartCareReminderScheduler.reminderIdentifier)
        let trigger = request?.trigger as? UNCalendarNotificationTrigger
        XCTAssertEqual(trigger?.repeats, true)
        XCTAssertEqual(trigger?.dateComponents.weekday, 2)
    }

    func test_update_cancelsWithoutSchedulingWhenOff() {
        preferences.remindSmartCare = false
        let scheduler = makeScheduler()

        scheduler.update()

        XCTAssertEqual(cancelled, [[SmartCareReminderScheduler.reminderIdentifier]])
        XCTAssertTrue(scheduled.isEmpty)
    }
}
