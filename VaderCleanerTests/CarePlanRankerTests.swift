// CarePlanRankerTests.swift
// Tests the deterministic feed ordering: threats always lead, byte findings rank by reclaimable size, and advisory findings follow in curated kind order.

import XCTest
@testable import VaderCleaner

final class CarePlanRankerTests: XCTestCase {

    private func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private func junk(bytes: Int64) -> CareFinding {
        CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [file("/cache", size: bytes)])))
    }

    private func largeOld(bytes: Int64) -> CareFinding {
        CareFinding(kind: .largeOldFiles, payload: .largeOldFiles([file("/big", size: bytes, category: .largeFile)]))
    }

    private var threats: CareFinding {
        CareFinding(
            kind: .threats,
            payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")])
        )
    }

    private var updates: CareFinding {
        CareFinding(kind: .appUpdates, payload: .appUpdates([]))
    }

    private var loginItems: CareFinding {
        CareFinding(kind: .loginItems, payload: .loginItems([]))
    }

    /// A disk past the critical threshold, which escalates the card to critical.
    private var lowDisk: CareFinding {
        CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(DiskStats(usedBytes: 95, totalBytes: 100)))
    }

    /// A disk that is filling but not critical — the fixture for tests about
    /// ordering among ordinary advisories, where escalation would be noise.
    private var mildLowDisk: CareFinding {
        CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(DiskStats(usedBytes: 85, totalBytes: 100)))
    }

    func test_threatsLead_evenWithZeroBytes() {
        let ranked = CarePlanRanker.ranked([junk(bytes: 10_000_000_000), threats])
        XCTAssertEqual(ranked.map(\.kind), [.threats, .junkCleanup])
    }

    func test_byteFindings_orderBySizeDescending() {
        let ranked = CarePlanRanker.ranked([junk(bytes: 100), largeOld(bytes: 900)])
        XCTAssertEqual(ranked.map(\.kind), [.largeOldFiles, .junkCleanup])
    }

    func test_advisoryFindings_followByteFindings_inKindOrder() {
        let ranked = CarePlanRanker.ranked([loginItems, updates, junk(bytes: 1), mildLowDisk])
        XCTAssertEqual(ranked.map(\.kind), [.junkCleanup, .lowDiskSpace, .appUpdates, .loginItems])
    }

    func test_equalBytes_breakTiesByKindDeclarationOrder() {
        let ranked = CarePlanRanker.ranked([largeOld(bytes: 500), junk(bytes: 500)])
        XCTAssertEqual(ranked.map(\.kind), [.junkCleanup, .largeOldFiles])
    }

    func test_ranking_isDeterministic() {
        let input = [loginItems, junk(bytes: 5), threats, updates, largeOld(bytes: 5)]
        XCTAssertEqual(
            CarePlanRanker.ranked(input).map(\.kind),
            CarePlanRanker.ranked(input.reversed()).map(\.kind)
        )
    }

    // MARK: - Severity context

    func test_sizedFindings_outrankCountOnlyFindings_whateverTheirScore() {
        // A single tiny junk find still leads a maxed-out advisory: bytes and
        // counts are different scales, and the space win is the actionable one.
        let ranked = CarePlanRanker.ranked([mildLowDisk, junk(bytes: 1)])
        XCTAssertEqual(ranked.map(\.kind), [.junkCleanup, .lowDiskSpace])
    }

    func test_criticallyFullDisk_leadsTheFeed_aboveLargerSpaceFindings() {
        let ranked = CarePlanRanker.ranked([junk(bytes: 40_000_000_000), lowDisk])
        XCTAssertEqual(ranked.map(\.kind), [.lowDiskSpace, .junkCleanup])
    }

    func test_diskPressure_liftsASafeWin_overAComparableOptInFinding() {
        let pressured = CareSeverityContext(
            health: CareHealthSnapshot(
                disk: DiskStats(usedBytes: 850, totalBytes: 1_000),
                memoryPressure: .nominal,
                smart: .good,
                battery: .absent
            )
        )
        let findings = [largeOld(bytes: 8_000_000_000), junk(bytes: 8_000_000_000)]
        XCTAssertEqual(
            CarePlanRanker.ranked(findings, context: pressured).map(\.kind),
            [.junkCleanup, .largeOldFiles]
        )
    }

    func test_rankingWithContext_isDeterministic() {
        let ctx = CareSeverityContext(
            health: CareHealthSnapshot(
                disk: DiskStats(usedBytes: 900, totalBytes: 1_000),
                memoryPressure: .nominal,
                smart: .good,
                battery: .absent
            )
        )
        let input = [loginItems, junk(bytes: 2_000_000_000), threats, updates, largeOld(bytes: 5)]
        XCTAssertEqual(
            CarePlanRanker.ranked(input, context: ctx).map(\.kind),
            CarePlanRanker.ranked(input.reversed(), context: ctx).map(\.kind)
        )
    }
}
