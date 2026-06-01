// LocalSnapshotCounterTests.swift
// Verifies LocalSnapshotCounter parses `tmutil listlocalsnapshots /` output into a count of local snapshots.

import XCTest
@testable import VaderCleaner

final class LocalSnapshotCounterTests: XCTestCase {

    func test_count_returnsZeroForNoSnapshots() {
        let counter = LocalSnapshotCounter(listSnapshots: {
            "Snapshots for disk /:\n"
        })
        XCTAssertEqual(counter.count(), 0)
    }

    func test_count_countsSnapshotLines() {
        let counter = LocalSnapshotCounter(listSnapshots: {
            """
            Snapshots for disk /:
            com.apple.TimeMachine.2026-05-29-120000.local
            com.apple.TimeMachine.2026-05-30-120000.local
            com.apple.TimeMachine.2026-05-30-180000.local
            """
        })
        XCTAssertEqual(counter.count(), 3)
    }

    func test_count_ignoresNonSnapshotNoise() {
        let counter = LocalSnapshotCounter(listSnapshots: {
            "garbage\ncom.apple.TimeMachine.2026-05-30-120000.local\n"
        })
        XCTAssertEqual(counter.count(), 1)
    }
}
