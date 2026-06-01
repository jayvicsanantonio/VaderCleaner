// PerformanceRecommendationEngineTests.swift
// Verifies the recommendation engine surfaces the right curated cards (RAM, maintenance, background items, snapshots) for a given system snapshot, in display order.

import XCTest
@testable import VaderCleaner

final class PerformanceRecommendationEngineTests: XCTestCase {

    func test_healthySystem_offersOnlyThePersistentRAMHero() {
        let snapshot = PerformanceSnapshot(
            memory: MemoryStats(usedBytes: 4_000_000_000, totalBytes: 16_000_000_000), // 25%
            localSnapshotCount: 0,
            backgroundItemCount: 0,
            staleTaskCount: 0
        )

        let recs = PerformanceRecommendationEngine.recommendations(for: snapshot)

        // RAM is a persistent hero; nothing else surfaces on a healthy system.
        XCTAssertEqual(recs.map(\.kind), [.freeUpRAM])
        XCTAssertTrue(recs.first?.isHero ?? false)
    }

    func test_freeUpRAM_isAlwaysTheHeroCard() {
        let snapshot = PerformanceSnapshot(
            memory: .empty,
            localSnapshotCount: 0,
            backgroundItemCount: 0,
            staleTaskCount: 0
        )

        let recs = PerformanceRecommendationEngine.recommendations(for: snapshot)

        XCTAssertEqual(recs.first?.kind, .freeUpRAM)
        XCTAssertTrue(recs.first?.isHero ?? false)
    }

    func test_staleTasks_recommendsMaintenanceWithCount() {
        let snapshot = PerformanceSnapshot(
            memory: .empty,
            localSnapshotCount: 0,
            backgroundItemCount: 0,
            staleTaskCount: 3
        )

        let recs = PerformanceRecommendationEngine.recommendations(for: snapshot)
        let maintenance = recs.first { $0.kind == .maintenanceTasks }

        XCTAssertNotNil(maintenance)
        XCTAssertTrue(maintenance?.title.contains("3") ?? false)
    }

    func test_backgroundItems_recommendsWithCount() {
        let snapshot = PerformanceSnapshot(
            memory: .empty,
            localSnapshotCount: 0,
            backgroundItemCount: 12,
            staleTaskCount: 0
        )

        let recs = PerformanceRecommendationEngine.recommendations(for: snapshot)
        let background = recs.first { $0.kind == .backgroundItems }

        XCTAssertNotNil(background)
        XCTAssertTrue(background?.title.contains("12") ?? false)
    }

    func test_localSnapshots_recommendsThinning() {
        let snapshot = PerformanceSnapshot(
            memory: .empty,
            localSnapshotCount: 5,
            backgroundItemCount: 0,
            staleTaskCount: 0
        )

        let recs = PerformanceRecommendationEngine.recommendations(for: snapshot)

        XCTAssertTrue(recs.contains { $0.kind == .thinSnapshots })
    }

    func test_recommendationOrder_isRamThenMaintenanceThenBackgroundThenSnapshots() {
        let snapshot = PerformanceSnapshot(
            memory: MemoryStats(usedBytes: 15_000_000_000, totalBytes: 16_000_000_000),
            localSnapshotCount: 5,
            backgroundItemCount: 12,
            staleTaskCount: 3
        )

        let kinds = PerformanceRecommendationEngine.recommendations(for: snapshot).map(\.kind)

        XCTAssertEqual(kinds, [.freeUpRAM, .maintenanceTasks, .backgroundItems, .thinSnapshots])
    }
}
