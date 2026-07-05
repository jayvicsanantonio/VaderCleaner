// DeviceBatteryMonitor.swift
// Best-effort low-battery alerts for connected input devices (mouse, keyboard, trackpad).

import Foundation
import IOKit

/// A connected device's reported battery level.
struct DeviceBattery: Equatable {
    let name: String
    let percent: Int
}

/// Notifies when a connected input device's battery drops to/under
/// `lowThreshold`, gated by `notifyDeviceBatteryLow` and a per-device cooldown.
///
/// The battery read is best-effort and quarantined in `readDeviceBatteries()`:
/// macOS exposes no public API for peripheral battery level, so it scrapes the
/// `AppleDeviceManagementHIDEventService` IORegistry entries and may return
/// nothing on some setups or break across OS releases. The reader is injected so
/// the firing logic stays fully unit-testable.
@MainActor
final class DeviceBatteryMonitor {

    typealias Reader = @Sendable () -> [DeviceBattery]

    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let reader: Reader
    private let lowThreshold: Int
    private let cooldown: TimeInterval
    private let pollInterval: TimeInterval
    private let now: () -> Date

    private var lastFired: [String: Date] = [:]
    private var timer: Timer?

    init(
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        reader: @escaping Reader = { DeviceBatteryMonitor.readDeviceBatteries() },
        lowThreshold: Int = 20,
        cooldown: TimeInterval = 12 * 60 * 60,
        pollInterval: TimeInterval = 15 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.reader = reader
        self.lowThreshold = lowThreshold
        self.cooldown = cooldown
        self.pollInterval = pollInterval
        self.now = now
    }

    /// Pure decision: fires for each device at/under the low threshold whose
    /// per-device cooldown has elapsed.
    func evaluate(devices: [DeviceBattery]) {
        guard preferences.notifyDeviceBatteryLow else { return }
        for device in devices where device.percent <= lowThreshold {
            if let last = lastFired[device.name], now().timeIntervalSince(last) < cooldown { continue }
            dispatcher.sendDeviceBatteryLowNotification(deviceName: device.name, percent: device.percent)
            lastFired[device.name] = now()
        }
    }

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard preferences.notifyDeviceBatteryLow else { return }
        evaluate(devices: reader())
    }

    /// Best-effort peripheral battery read via IORegistry. Returns `[]` when no
    /// device reports a level.
    nonisolated static func readDeviceBatteries() -> [DeviceBattery] {
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [DeviceBattery] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let percent = property(service, "BatteryPercent") as? Int {
                let name = (property(service, "Product") as? String) ?? "Device"
                result.append(DeviceBattery(name: name, percent: percent))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    nonisolated private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
