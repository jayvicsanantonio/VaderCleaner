// TrashSizeMonitorTests.swift
// Verifies the Trash-size monitor fires only past the threshold, respects the toggle, and honors its cooldown.

import Foundation
import Testing
import XCTest
@testable import VaderCleanerCore

@MainActor
final class TrashSizeMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!
    private var virtualNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        try await super.setUp()
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

@MainActor
@Suite
struct TrashSizeMonitorOverlapTests {

    /// `start()` used to schedule a plain repeating `Timer` that kicked off a
    /// fresh `poll()` Task on every tick regardless of whether the previous
    /// poll had returned. A slow `sizeReader` (a large real Trash) could
    /// therefore have two polls measuring at once. This drives a `sizeReader`
    /// slower than the poll interval and asserts the peak concurrency never
    /// exceeds 1.
    @Test
    func start_neverRunsOverlappingPolls() async throws {
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.TrashSizeOverlap.\(UUID().uuidString)")!
        let preferences = PreferencesStore(defaults: defaults)
        preferences.notifyTrashSize = true
        preferences.trashSizeThresholdGB = 1_000_000 // never actually fires a notification
        let dispatcher = StubNotificationDispatcher()
        let tracker = ConcurrencyPeakTracker()

        let monitor = TrashSizeMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            sizeReader: {
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(60))
                await tracker.exit()
                return 0
            },
            cooldown: 0,
            pollInterval: 0.02,
            now: Date.init
        )

        monitor.start()
        try await Task.sleep(for: .milliseconds(250))
        monitor.stop()

        #expect(await tracker.peak == 1)
    }
}
