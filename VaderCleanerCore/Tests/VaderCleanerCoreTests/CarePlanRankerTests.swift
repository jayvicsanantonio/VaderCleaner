// CarePlanRankerTests.swift
// Tests the deterministic feed ordering: threats always lead, byte findings rank by reclaimable size, and advisory findings follow in curated kind order.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct CarePlanRankerTests {

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
        CareFinding(payload: .junk(ScanResult(items: [file("/cache", size: bytes)])))
    }

    private func largeOld(bytes: Int64) -> CareFinding {
        CareFinding(payload: .largeOldFiles([file("/big", size: bytes, category: .largeFile)]))
    }

    private var threats: CareFinding {
        CareFinding(payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")])
        )
    }

    private var updates: CareFinding {
        CareFinding(payload: .appUpdates([]))
    }

    private var loginItems: CareFinding {
        CareFinding(payload: .loginItems([]))
    }

    /// A disk past the critical threshold, which escalates the card to critical.
    private var lowDisk: CareFinding {
        CareFinding(payload: .lowDiskSpace(DiskStats(usedBytes: 95, totalBytes: 100)))
    }

    /// A disk that is filling but not critical — the fixture for tests about
    /// ordering among ordinary advisories, where escalation would be noise.
    private var mildLowDisk: CareFinding {
        CareFinding(payload: .lowDiskSpace(DiskStats(usedBytes: 85, totalBytes: 100)))
    }

    @Test
    func threatsLead_evenWithZeroBytes() {
        let ranked = CarePlanRanker.ranked([junk(bytes: 10_000_000_000), threats])
        #expect(ranked.map(\.kind) == [.threats, .junkCleanup])
    }

    @Test
    func byteFindings_orderBySizeDescending() {
        let ranked = CarePlanRanker.ranked([junk(bytes: 100), largeOld(bytes: 900)])
        #expect(ranked.map(\.kind) == [.largeOldFiles, .junkCleanup])
    }

    @Test
    func advisoryFindings_followByteFindings_inKindOrder() {
        let ranked = CarePlanRanker.ranked([loginItems, updates, junk(bytes: 1), mildLowDisk])
        #expect(ranked.map(\.kind) == [.junkCleanup, .lowDiskSpace, .appUpdates, .loginItems])
    }

    @Test
    func equalBytes_breakTiesByKindDeclarationOrder() {
        let ranked = CarePlanRanker.ranked([largeOld(bytes: 500), junk(bytes: 500)])
        #expect(ranked.map(\.kind) == [.junkCleanup, .largeOldFiles])
    }

    @Test
    func ranking_isDeterministic() {
        let input = [loginItems, junk(bytes: 5), threats, updates, largeOld(bytes: 5)]
        #expect(
            CarePlanRanker.ranked(input).map(\.kind) == CarePlanRanker.ranked(input.reversed()).map(\.kind)
        )
    }

    // MARK: - Severity context

    @Test
    func sizedFindings_outrankCountOnlyFindings_whateverTheirScore() {
        // A single tiny junk find still leads a maxed-out advisory: bytes and
        // counts are different scales, and the space win is the actionable one.
        let ranked = CarePlanRanker.ranked([mildLowDisk, junk(bytes: 1)])
        #expect(ranked.map(\.kind) == [.junkCleanup, .lowDiskSpace])
    }

    @Test
    func criticallyFullDisk_leadsTheFeed_aboveLargerSpaceFindings() {
        let ranked = CarePlanRanker.ranked([junk(bytes: 40_000_000_000), lowDisk])
        #expect(ranked.map(\.kind) == [.lowDiskSpace, .junkCleanup])
    }

    @Test
    func diskPressure_liftsASafeWin_overAComparableOptInFinding() {
        let pressured = CareSeverityContext(
            health: CareHealthSnapshot(
                disk: DiskStats(usedBytes: 850, totalBytes: 1_000),
                memoryPressure: .nominal,
                smart: .good,
                battery: .absent
            )
        )
        let findings = [largeOld(bytes: 8_000_000_000), junk(bytes: 8_000_000_000)]
        #expect(
            CarePlanRanker.ranked(findings, context: pressured).map(\.kind) == [.junkCleanup, .largeOldFiles]
        )
    }

    @Test
    func regrownFinding_outranksAQuietPeerOfTheSameSize() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cleared = CareReceipt(
            date: now.addingTimeInterval(-86_400),
            lines: [CareReceiptLine(kind: .installers, itemsProcessed: 4, bytesFreed: 0, outcome: .success)]
        )
        let regrown = CareFinding(payload: .installers((0..<4).map {
            InstallationFile(
                url: URL(fileURLWithPath: "/Downloads/app\($0).dmg"),
                name: "app\($0).dmg",
                sizeBytes: 1_000_000_000,
                kind: .diskImage
            )
        }))
        let quiet = largeOld(bytes: 4_000_000_000)
        let ranked = CarePlanRanker.ranked(
            [quiet, regrown],
            context: CareSeverityContext(health: nil, receipts: [cleared], now: now)
        )
        #expect(ranked.map(\.kind) == [.installers, .largeOldFiles])
    }

    @Test
    func rankingWithContext_isDeterministic() {
        let ctx = CareSeverityContext(
            health: CareHealthSnapshot(
                disk: DiskStats(usedBytes: 900, totalBytes: 1_000),
                memoryPressure: .nominal,
                smart: .good,
                battery: .absent
            )
        )
        let input = [loginItems, junk(bytes: 2_000_000_000), threats, updates, largeOld(bytes: 5)]
        #expect(
            CarePlanRanker.ranked(input, context: ctx).map(\.kind)
                == CarePlanRanker.ranked(input.reversed(), context: ctx).map(\.kind)
        )
    }
}
