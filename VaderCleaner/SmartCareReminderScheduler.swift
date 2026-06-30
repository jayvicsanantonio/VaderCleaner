// SmartCareReminderScheduler.swift
// Schedules a repeating "time for Smart Care" reminder at the user's chosen cadence.

import Foundation
import UserNotifications

/// Keeps a single repeating reminder notification in sync with the
/// `remindSmartCare` toggle and `smartCareFrequency`. The schedule/cancel sinks
/// are injected so `update()` can be unit-tested without scheduling against the
/// real `UNUserNotificationCenter`.
@MainActor
final class SmartCareReminderScheduler {

    /// Stable identifier so re-applying replaces the existing reminder rather
    /// than stacking duplicates.
    static let reminderIdentifier = "com.personal.VaderCleaner.smartCareReminder"

    typealias Schedule = (UNNotificationRequest) -> Void
    typealias Cancel = ([String]) -> Void

    private let preferences: PreferencesStore
    private let schedule: Schedule
    private let cancel: Cancel

    init(
        preferences: PreferencesStore,
        schedule: @escaping Schedule = { UNUserNotificationCenter.current().add($0) },
        cancel: @escaping Cancel = { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) }
    ) {
        self.preferences = preferences
        self.schedule = schedule
        self.cancel = cancel
    }

    /// (Re)applies the reminder from the current preferences: schedules a
    /// repeating notification at the chosen cadence, or cancels it when the
    /// toggle is off. Idempotent — always clears the prior request first.
    func update() {
        cancel([Self.reminderIdentifier])
        guard preferences.remindSmartCare else { return }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Self.dateComponents(for: preferences.smartCareFrequency),
            repeats: true
        )
        let request = UNNotificationRequest(
            identifier: Self.reminderIdentifier,
            content: NotificationManager.makeSmartCareReminderContent(),
            trigger: trigger
        )
        schedule(request)
    }

    /// The calendar match for a cadence. All fire at 10:00 local time; weekly
    /// lands on Monday and monthly on the 1st, so the reminder is predictable.
    static func dateComponents(for frequency: SmartCareFrequency) -> DateComponents {
        var components = DateComponents()
        components.hour = 10
        components.minute = 0
        switch frequency {
        case .daily:
            break
        case .weekly:
            components.weekday = 2   // Monday (1 = Sunday)
        case .monthly:
            components.day = 1
        }
        return components
    }
}
