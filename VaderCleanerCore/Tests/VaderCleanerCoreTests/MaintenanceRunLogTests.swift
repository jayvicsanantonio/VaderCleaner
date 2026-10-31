// MaintenanceRunLogTests.swift
// Verifies MaintenanceRunLog persists and reads per-task last-run timestamps and reports which tasks are stale.

import Foundation
import Testing
import XCTest
@testable import VaderCleanerCore

final class MaintenanceRunLogTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MaintenanceRunLogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_lastRun_isNilBeforeAnyRun() {
        let log = MaintenanceRunLog(defaults: defaults)
        XCTAssertNil(log.lastRun(for: "flushDNS"))
    }

    func test_record_thenLastRun_roundTrips() {
        let log = MaintenanceRunLog(defaults: defaults)
        let when = Date(timeIntervalSinceReferenceDate: 1000)

        log.record("flushDNS", at: when)

        XCTAssertEqual(log.lastRun(for: "flushDNS"), when)
    }

    func test_record_persistsAcrossInstances() {
        let when = Date(timeIntervalSinceReferenceDate: 2000)
        MaintenanceRunLog(defaults: defaults).record("reindexSpotlight", at: when)

        let reloaded = MaintenanceRunLog(defaults: defaults)

        XCTAssertEqual(reloaded.lastRun(for: "reindexSpotlight"), when)
    }

    func test_staleTaskCount_countsNeverRunAndOlderThanWindow() {
        let log = MaintenanceRunLog(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // Ran 1 day ago — fresh.
        log.record("a", at: now.addingTimeInterval(-86_400))
        // Ran 10 days ago — stale.
        log.record("b", at: now.addingTimeInterval(-10 * 86_400))

        // "a" fresh, "b" stale, "c" never run → 2 stale.
        let stale = log.staleTaskCount(among: ["a", "b", "c"], now: now)

        XCTAssertEqual(stale, 2)
    }
}

/// A clock that was wrong when a run was recorded must not keep the task from
/// ever coming due again.
@Suite
struct MaintenanceRunLogClockTests {

    @Test
    func aRunStampedInTheFutureCountsAsStale() throws {
        let suiteName = "MaintenanceRunLogClockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let log = MaintenanceRunLog(defaults: defaults)
        let now = Date()
        log.record("flushDNS", at: now.addingTimeInterval(365 * 24 * 60 * 60))

        #expect(log.staleTaskIDs(among: ["flushDNS"], now: now) == ["flushDNS"])
    }
}
