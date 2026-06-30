// DeviceBatteryMonitorTests.swift
// Verifies device low-battery dispatch against the threshold, toggle, and per-device cooldown.

import XCTest
@testable import VaderCleaner

@MainActor
final class DeviceBatteryMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!
    private var virtualNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.DeviceBattery.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
    }

    private func makeMonitor() -> DeviceBatteryMonitor {
        DeviceBatteryMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            reader: { [] },
            lowThreshold: 20,
            cooldown: 12 * 60 * 60,
            now: { [unowned self] in self.virtualNow }
        )
    }

    func test_fires_forDeviceAtOrUnderThreshold() {
        preferences.notifyDeviceBatteryLow = true
        let monitor = makeMonitor()

        monitor.evaluate(devices: [DeviceBattery(name: "Magic Mouse", percent: 15)])

        XCTAssertEqual(dispatcher.calls, [.deviceBatteryLow(deviceName: "Magic Mouse", percent: 15)])
    }

    func test_doesNotFire_aboveThreshold() {
        preferences.notifyDeviceBatteryLow = true
        let monitor = makeMonitor()

        monitor.evaluate(devices: [DeviceBattery(name: "Magic Keyboard", percent: 80)])

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_doesNotFire_whenToggleOff() {
        preferences.notifyDeviceBatteryLow = false
        let monitor = makeMonitor()

        monitor.evaluate(devices: [DeviceBattery(name: "Trackpad", percent: 5)])

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_cooldown_isPerDevice() {
        preferences.notifyDeviceBatteryLow = true
        let monitor = makeMonitor()

        monitor.evaluate(devices: [DeviceBattery(name: "Mouse", percent: 10)])
        // Same device again inside cooldown — suppressed; a different low device fires.
        monitor.evaluate(devices: [
            DeviceBattery(name: "Mouse", percent: 9),
            DeviceBattery(name: "Keyboard", percent: 8)
        ])

        XCTAssertEqual(dispatcher.calls, [
            .deviceBatteryLow(deviceName: "Mouse", percent: 10),
            .deviceBatteryLow(deviceName: "Keyboard", percent: 8)
        ])
    }
}
