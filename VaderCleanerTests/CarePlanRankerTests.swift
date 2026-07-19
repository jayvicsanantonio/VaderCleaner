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

    private var lowDisk: CareFinding {
        CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(DiskStats(usedBytes: 95, totalBytes: 100)))
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
        let ranked = CarePlanRanker.ranked([loginItems, updates, junk(bytes: 1), lowDisk])
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
}
