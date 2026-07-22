// SystemStatsActivationTests.swift
// Tests the reference-counted polling gate: stats only tick while something is actually displaying them.

import XCTest
@testable import VaderCleaner

@MainActor
final class SystemStatsActivationTests: XCTestCase {

    private func makeService() -> SystemStatsService {
        SystemStatsService(interval: 2.0, autostart: false)
    }

    /// The whole point: a service nobody is watching must not be polling. The
    /// old behaviour started a 2-second timer at launch and never stopped it,
    /// so a closed window with a hidden menu bar still sampled RAM, disk, CPU
    /// and network forever.
    func test_isPolling_startsFalse() {
        XCTAssertFalse(makeService().isPolling)
    }

    func test_beginUpdates_startsPolling() {
        let service = makeService()

        service.beginUpdates()

        XCTAssertTrue(service.isPolling)
    }

    func test_endUpdates_stopsPolling() {
        let service = makeService()
        service.beginUpdates()

        service.endUpdates()

        XCTAssertFalse(service.isPolling)
    }

    /// Several surfaces can want stats at once — the panel, the main window,
    /// the menu bar reading. Polling must survive until the last one lets go.
    func test_pollingSurvivesUntilTheLastObserverLeaves() {
        let service = makeService()
        service.beginUpdates()
        service.beginUpdates()

        service.endUpdates()
        XCTAssertTrue(service.isPolling, "one observer remains")

        service.endUpdates()
        XCTAssertFalse(service.isPolling)
    }

    /// SwiftUI can fire `onDisappear` more times than `onAppear` across view
    /// rebuilds; an unbalanced release must not drive the count negative and
    /// wedge polling off forever.
    func test_extraEndUpdates_cannotWedgePollingOff() {
        let service = makeService()

        service.endUpdates()
        service.endUpdates()
        service.beginUpdates()

        XCTAssertTrue(service.isPolling)
    }

    func test_reactivatesAfterEveryoneLeavesAndReturns() {
        let service = makeService()
        service.beginUpdates()
        service.endUpdates()

        service.beginUpdates()

        XCTAssertTrue(service.isPolling)
    }

    // MARK: - Cadence

    func test_updateInterval_isAdjustable() {
        let service = makeService()

        service.updateInterval = 10

        XCTAssertEqual(service.updateInterval, 10)
    }

    /// Changing the cadence while polling has to re-arm the timer, or the new
    /// interval silently doesn't take effect until something else restarts it.
    func test_changingIntervalWhilePolling_keepsPolling() {
        let service = makeService()
        service.beginUpdates()

        service.updateInterval = 5

        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(service.updateInterval, 5)
    }

    func test_changingIntervalWhileIdle_doesNotStartPolling() {
        let service = makeService()

        service.updateInterval = 5

        XCTAssertFalse(service.isPolling)
    }
}
