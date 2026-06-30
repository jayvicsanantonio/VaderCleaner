// NotificationMonitors.swift
// Owns and starts the background monitors behind the Notifications settings (trash, drives, devices, hung apps, trashed apps, Smart Care reminder).

import Foundation
import Observation

/// App-scoped aggregator for the notification monitors introduced alongside the
/// Notifications settings pane. It constructs each monitor against the shared
/// `PreferencesStore` + `NotificationDispatching`, starts them once, and keeps
/// the Smart Care reminder in sync as its preference changes.
///
/// Held as `@State` by `VaderCleanerApp` and started from the same post-launch
/// path that requests notification permission, so the OS prompt has resolved
/// before any banner can fire.
@MainActor
@Observable
final class NotificationMonitors {

    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private let trashSize: TrashSizeMonitor
    @ObservationIgnored private let volumeMount: VolumeMountMonitor
    @ObservationIgnored private let deviceBattery: DeviceBatteryMonitor
    @ObservationIgnored private let hungApp: HungAppMonitor
    @ObservationIgnored private let trashedApp: TrashedAppMonitor
    @ObservationIgnored private let smartCare: SmartCareReminderScheduler
    @ObservationIgnored private var started = false

    init(preferences: PreferencesStore, dispatcher: NotificationDispatching) {
        self.preferences = preferences
        self.trashSize = TrashSizeMonitor(preferences: preferences, dispatcher: dispatcher)
        self.volumeMount = VolumeMountMonitor(preferences: preferences, dispatcher: dispatcher)
        self.deviceBattery = DeviceBatteryMonitor(preferences: preferences, dispatcher: dispatcher)
        self.hungApp = HungAppMonitor(preferences: preferences, dispatcher: dispatcher)
        self.trashedApp = TrashedAppMonitor(preferences: preferences, dispatcher: dispatcher)
        self.smartCare = SmartCareReminderScheduler(preferences: preferences)
    }

    /// Starts every monitor and schedules the Smart Care reminder. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        trashSize.start()
        volumeMount.start()
        deviceBattery.start()
        hungApp.start()
        trashedApp.start()
        smartCare.update()
        observeSmartCarePreference()
    }

    /// Re-applies the Smart Care reminder whenever its toggle or cadence changes,
    /// re-arming the observation each time (Observation fires once per change).
    private func observeSmartCarePreference() {
        withObservationTracking {
            _ = preferences.remindSmartCare
            _ = preferences.smartCareFrequency
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.smartCare.update()
                self.observeSmartCarePreference()
            }
        }
    }
}
