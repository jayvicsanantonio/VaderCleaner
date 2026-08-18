// CareVerdictEngineTests.swift
// Tests the pure verdict derivation: base tier from health telemetry, severity caps from findings, and plain-language headline/detail composition.

import XCTest
@testable import VaderCleaner

final class CareVerdictEngineTests: XCTestCase {

    // MARK: - Fixtures

    private let healthyTelemetry = CareHealthSnapshot(
        disk: DiskStats(usedBytes: 100, totalBytes: 1_000),
        memoryPressure: .nominal,
        smart: .good,
        battery: .absent
    )

    private func junkFinding(bytes: Int64) -> CareFinding {
        let file = ScannedFile(
            url: URL(fileURLWithPath: "/cache/blob"),
            size: bytes,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        return CareFinding(payload: .junk(ScanResult(items: [file])))
    }

    private var threatFinding: CareFinding {
        CareFinding(payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")])
        )
    }

    private func plan(findings: [CareFinding], health: CareHealthSnapshot?) -> CarePlan {
        CarePlan(
            findings: findings,
            health: health,
            unitOutcomes: [:],
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
    }

    // MARK: - Tiers

    func test_healthyMacWithNothingFound_isExcellent() {
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [], health: healthyTelemetry))
        XCTAssertEqual(verdict.status, .excellent)
    }

    func test_unmeasuredHealth_defaultsToGoodBase() {
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [], health: nil))
        XCTAssertEqual(verdict.status, .good)
    }

    func test_threats_capAtRequiresAttention() {
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [threatFinding], health: healthyTelemetry))
        XCTAssertEqual(verdict.status, .requiresAttention)
    }

    func test_largeSafeJunk_capsAtFair() {
        let verdict = CareVerdictEngine.verdict(
            for: plan(findings: [junkFinding(bytes: CareVerdictEngine.safeJunkCapBytes + 1)], health: healthyTelemetry)
        )
        XCTAssertEqual(verdict.status, .fair)
    }

    func test_heavySafeJunk_capsAtRequiresAttention() {
        // 94 GB of clearable junk is not "a little care".
        let verdict = CareVerdictEngine.verdict(
            for: plan(findings: [junkFinding(bytes: CareVerdictEngine.heavyJunkCapBytes + 1)], health: healthyTelemetry)
        )
        XCTAssertEqual(verdict.status, .requiresAttention)
    }

    func test_junkBetweenTheTwoCaps_staysFair() {
        let midpoint = (CareVerdictEngine.safeJunkCapBytes + CareVerdictEngine.heavyJunkCapBytes) / 2
        let verdict = CareVerdictEngine.verdict(
            for: plan(findings: [junkFinding(bytes: midpoint)], health: healthyTelemetry)
        )
        XCTAssertEqual(verdict.status, .fair)
    }

    func test_heavyJunkCap_sitsAboveTheFairCap() {
        // The two thresholds must stay ordered, or the tiers invert.
        XCTAssertGreaterThan(CareVerdictEngine.heavyJunkCapBytes, CareVerdictEngine.safeJunkCapBytes)
    }

    func test_junkAlone_neverReachesCritical_howeverMuchOfItThereIs() {
        // Junk is all safely removable. Critical is reserved for a disk about
        // to stop working, not for a big pile of caches.
        let verdict = CareVerdictEngine.verdict(
            for: plan(findings: [junkFinding(bytes: 900_000_000_000)], health: healthyTelemetry)
        )
        XCTAssertGreaterThan(verdict.status, .critical)
    }

    func test_smallSafeJunk_doesNotCap() {
        let verdict = CareVerdictEngine.verdict(
            for: plan(findings: [junkFinding(bytes: 1_000)], health: healthyTelemetry)
        )
        XCTAssertEqual(verdict.status, .excellent)
    }

    func test_optInBytes_neverCapTheVerdict() {
        // 100 GB of the user's own large files is not "an unhealthy Mac".
        let big = ScannedFile(
            url: URL(fileURLWithPath: "/Movies/raw.mov"),
            size: 100_000_000_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .largeFile
        )
        let finding = CareFinding(payload: .largeOldFiles([big]))
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [finding], health: healthyTelemetry))
        XCTAssertEqual(verdict.status, .excellent)
    }

    func test_nearlyFullDisk_lowersTheBaseTier() {
        let fullDisk = CareHealthSnapshot(
            disk: DiskStats(usedBytes: 960, totalBytes: 1_000),
            memoryPressure: .nominal,
            smart: .good,
            battery: .absent
        )
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [], health: fullDisk))
        XCTAssertEqual(verdict.status, .requiresAttention)
    }

    func test_capsOnlyLower_neverRaise() {
        let failingDisk = CareHealthSnapshot(
            disk: DiskStats(usedBytes: 990, totalBytes: 1_000),
            memoryPressure: .nominal,
            smart: .failing,
            battery: .absent
        )
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [threatFinding], health: failingDisk))
        XCTAssertEqual(verdict.status, .critical, "a threat cap must not raise a critical hardware verdict")
    }

    func test_criticallyFullDiskFinding_capsTheVerdictAtCritical() {
        let finding = CareFinding(payload: .lowDiskSpace(DiskStats(usedBytes: 990, totalBytes: 1_000))
        )
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [finding], health: healthyTelemetry))
        XCTAssertEqual(verdict.status, .critical)
    }

    func test_fillingButNotCriticalDiskFinding_doesNotCapAtCritical() {
        let finding = CareFinding(payload: .lowDiskSpace(DiskStats(usedBytes: 850, totalBytes: 1_000))
        )
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [finding], health: healthyTelemetry))
        XCTAssertGreaterThan(verdict.status, .critical)
    }

    func test_threats_stillCapAtRequiresAttention_notCritical() {
        // Threats carry a critical *finding* urgency; that must not be confused
        // with a critical verdict for the whole Mac.
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [threatFinding], health: healthyTelemetry))
        XCTAssertEqual(verdict.status, .requiresAttention)
    }

    // MARK: - Copy

    func test_headlines_areDistinctAndNonEmpty_perTier() {
        var headlines = Set<String>()
        for status in MacHealthStatus.allCases {
            let headline = CareVerdictEngine.headline(for: status)
            XCTAssertFalse(headline.isEmpty)
            headlines.insert(headline)
        }
        XCTAssertEqual(headlines.count, MacHealthStatus.allCases.count)
    }

    func test_detail_nothingFound_saysSo() {
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [], health: healthyTelemetry))
        XCTAssertFalse(verdict.detail.isEmpty)
    }

    func test_detail_includesSafelyFreeableBytes() {
        let verdict = CareVerdictEngine.verdict(
            for: plan(findings: [junkFinding(bytes: 2_300_000_000)], health: healthyTelemetry)
        )
        XCTAssertTrue(
            verdict.detail.contains(CareFindingCopy.formattedBytes(2_300_000_000)),
            "detail should quote the safely-freeable byte total: \(verdict.detail)"
        )
    }

    func test_detail_countsOnlyActionableFindings() {
        let info = CareFinding(payload: .loginItems([
            LoginItem(id: "a", name: "Agent", isEnabled: true)
        ]))
        let verdict = CareVerdictEngine.verdict(for: plan(findings: [info], health: healthyTelemetry))
        XCTAssertFalse(verdict.detail.contains("1 thing"), "informational findings are not 'things worth doing'")
    }

    func test_detail_withSuppliedCountAndBytes_quotesTheFixScopeNotTheGross() {
        // The feed passes the pre-approved count and its selected bytes so the
        // hero speaks to what Fix handles; the plan's gross figures are larger.
        let carePlan = plan(findings: [junkFinding(bytes: 110_000_000_000)], health: healthyTelemetry)
        let detail = CareVerdictEngine.detail(
            for: carePlan,
            readyCount: 4,
            safeFreeableBytes: 94_650_000_000
        )
        XCTAssertTrue(detail.contains("4 things"), "hero counts only what Fix handles: \(detail)")
        XCTAssertTrue(
            detail.contains(CareFindingCopy.formattedBytes(94_650_000_000)),
            "detail should quote the supplied selected total: \(detail)"
        )
        XCTAssertFalse(
            detail.contains(CareFindingCopy.formattedBytes(110_000_000_000)),
            "detail must not quote the gross found total"
        )
    }

    func test_detail_readyCountZero_pointsAtOptInWorkInstead() {
        // Actionable work exists but none of it is pre-approved: the hero must
        // not say "0 things worth doing" — it points at the zones below.
        let optIn = CareFinding(payload: .largeOldFiles([
            ScannedFile(url: URL(fileURLWithPath: "/big"), size: 9_000_000_000,
                        lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
        ]))
        let detail = CareVerdictEngine.detail(
            for: plan(findings: [optIn], health: healthyTelemetry),
            readyCount: 0,
            safeFreeableBytes: 0
        )
        XCTAssertFalse(detail.contains("0 things"), "never quote a zero count: \(detail)")
        XCTAssertFalse(detail.isEmpty)
    }
}
