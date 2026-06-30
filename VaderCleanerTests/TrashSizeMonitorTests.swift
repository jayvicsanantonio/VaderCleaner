// TrashSizeMonitorTests.swift
// Verifies the Trash-size monitor fires only past the threshold, respects the toggle, and honors its cooldown.

import XCTest
@testable import VaderCleaner

@MainActor
final class TrashSizeMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!
    private var virtualNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.TrashSize.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
    }

    private func makeMonitor() -> TrashSizeMonitor {
        TrashSizeMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            sizeReader: { 0 },
            cooldown: 6 * 60 * 60,
            now: { [unowned self] in self.virtualNow }
        )
    }

    func test_fires_whenSizeOverThresholdAndToggleOn() {
        preferences.notifyTrashSize = true
        preferences.trashSizeThresholdGB = 2
        let monitor = makeMonitor()

        monitor.evaluate(sizeBytes: 3_000_000_000)

        XCTAssertEqual(dispatcher.calls, [.trashSize(sizeBytes: 3_000_000_000)])
    }

    func test_doesNotFire_whenToggleOff() {
        preferences.notifyTrashSize = false
        preferences.trashSizeThresholdGB = 2
        let monitor = makeMonitor()

        monitor.evaluate(sizeBytes: 9_000_000_000)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_doesNotFire_atOrBelowThreshold() {
        preferences.notifyTrashSize = true
        preferences.trashSizeThresholdGB = 2
        let monitor = makeMonitor()

        monitor.evaluate(sizeBytes: 2_000_000_000)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_cooldown_suppressesThenAllowsRefire() {
        preferences.notifyTrashSize = true
        preferences.trashSizeThresholdGB = 1
        let monitor = makeMonitor()

        monitor.evaluate(sizeBytes: 2_000_000_000)
        virtualNow = virtualNow.addingTimeInterval(60)         // within cooldown
        monitor.evaluate(sizeBytes: 2_000_000_000)
        XCTAssertEqual(dispatcher.calls.count, 1)

        virtualNow = virtualNow.addingTimeInterval(6 * 60 * 60 + 1)  // past cooldown
        monitor.evaluate(sizeBytes: 2_000_000_000)
        XCTAssertEqual(dispatcher.calls.count, 2)
    }
}
