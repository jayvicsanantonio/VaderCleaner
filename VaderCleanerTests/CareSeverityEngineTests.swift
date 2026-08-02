// CareSeverityEngineTests.swift
// Tests the pure severity derivation: kind-derived base tier, disk-pressure escalation and boost, and the magnitude score that orders findings within a tier.

import XCTest
@testable import VaderCleaner

final class CareSeverityEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot(usedRatio: Double) -> CareHealthSnapshot {
        CareHealthSnapshot(
            disk: DiskStats(usedBytes: UInt64(usedRatio * 1_000), totalBytes: 1_000),
            memoryPressure: .nominal,
            smart: .good,
            battery: .absent
        )
    }

    private func context(usedRatio: Double) -> CareSeverityContext {
        CareSeverityContext(health: snapshot(usedRatio: usedRatio))
    }

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

    private func lowDisk(usedRatio: Double) -> CareFinding {
        CareFinding(
            kind: .lowDiskSpace,
            payload: .lowDiskSpace(DiskStats(usedBytes: UInt64(usedRatio * 1_000), totalBytes: 1_000))
        )
    }

    private func updates(_ count: Int) -> CareFinding {
        let list = (0..<count).map { index in
            UpdateInfo(
                appName: "App\(index)",
                bundleID: "com.example.app\(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/App\(index).app"),
                installedVersion: "1.0",
                latestVersion: "2.0",
                source: .sparkle,
                updateURL: URL(string: "https://example.com")!
            )
        }
        return CareFinding(kind: .appUpdates, payload: .appUpdates(list))
    }

    private func severity(_ finding: CareFinding, _ context: CareSeverityContext = .none) -> CareSeverity {
        CareSeverityEngine.severity(for: finding, context: context)
    }

    // MARK: - Base tier

    func test_baseTier_matchesTheKindsUrgency_withEmptyContext() {
        for finding in [junk(bytes: 5_000), largeOld(bytes: 5_000), updates(3), lowDisk(usedRatio: 0.5)] {
            XCTAssertEqual(
                severity(finding).urgency,
                finding.urgency,
                "an empty context must never move \(finding.kind) off its kind-derived tier"
            )
        }
    }

    func test_appUpdates_stayAttention_atEveryCount() {
        for count in [1, 20, 200] {
            XCTAssertEqual(severity(updates(count), context(usedRatio: 0.99)).urgency, .attention)
        }
    }

    // MARK: - Disk-pressure escalation

    func test_lowDiskSpace_at99Percent_escalatesToCritical() {
        let result = severity(lowDisk(usedRatio: 0.99), context(usedRatio: 0.99))
        XCTAssertEqual(result.urgency, .critical)
        XCTAssertTrue(result.signals.contains(.diskPressure))
    }

    func test_lowDiskSpace_at91Percent_staysAttention() {
        XCTAssertEqual(severity(lowDisk(usedRatio: 0.91), context(usedRatio: 0.91)).urgency, .attention)
    }

    func test_lowDiskSpace_readsItsOwnPayload_notTheContext() {
        // The card describes a specific volume; its escalation must follow that
        // payload even when the health snapshot is missing.
        XCTAssertEqual(severity(lowDisk(usedRatio: 0.99)).urgency, .critical)
    }

    func test_diskThresholds_areTheHealthMonitorConstants_notCopies() {
        XCTAssertEqual(CareSeverityEngine.diskCriticalThreshold, HealthMonitorViewModel.diskCriticalThreshold)
        XCTAssertEqual(CareSeverityEngine.diskWarningThreshold, HealthMonitorViewModel.diskWarningThreshold)
    }

    // MARK: - Disk-pressure boost

    func test_largePreApprovedFinding_underDiskPressure_outscoresItsQuietSelf() {
        let big = junk(bytes: 8_000_000_000)
        XCTAssertGreaterThan(
            severity(big, context(usedRatio: 0.85)).score,
            severity(big, context(usedRatio: 0.20)).score
        )
        XCTAssertTrue(severity(big, context(usedRatio: 0.85)).signals.contains(.diskPressure))
    }

    func test_optInFinding_underDiskPressure_getsNoBoost() {
        // The user's own files are their call — pressure must not make the app
        // push harder on data it isn't allowed to remove unattended.
        let big = largeOld(bytes: 8_000_000_000)
        XCTAssertEqual(
            severity(big, context(usedRatio: 0.85)).score,
            severity(big, context(usedRatio: 0.20)).score,
            accuracy: 0.0001
        )
        XCTAssertFalse(severity(big, context(usedRatio: 0.85)).signals.contains(.diskPressure))
    }

    func test_findingBelowTheBoostFloor_underDiskPressure_getsNoBoost() {
        let small = junk(bytes: 500_000_000)
        XCTAssertEqual(
            severity(small, context(usedRatio: 0.85)).score,
            severity(small, context(usedRatio: 0.20)).score,
            accuracy: 0.0001
        )
    }

    func test_diskPressureBoost_needsPressure() {
        let big = junk(bytes: 8_000_000_000)
        XCTAssertFalse(severity(big, context(usedRatio: 0.50)).signals.contains(.diskPressure))
    }

    // MARK: - Score

    func test_score_isMonotonicInBytes_forSizedFindings() {
        let sizes: [Int64] = [1_000, 50_000_000, 900_000_000, 6_000_000_000, 40_000_000_000]
        let scores = sizes.map { severity(junk(bytes: $0)).score }
        XCTAssertEqual(scores, scores.sorted(), "score must never fall as bytes rise")
    }

    func test_score_separatesLargeFindings_moreThanSmallOnes() {
        // The point of log scaling: 40 GB vs 6 GB is a real difference worth
        // ordering on; 200 MB vs 100 MB is noise that should not dominate.
        let bigGap = severity(junk(bytes: 40_000_000_000)).score - severity(junk(bytes: 6_000_000_000)).score
        let smallGap = severity(junk(bytes: 200_000_000)).score - severity(junk(bytes: 100_000_000)).score
        XCTAssertGreaterThan(bigGap, smallGap)
    }

    func test_score_isClampedToOne_aboveTheCeiling() {
        let huge = junk(bytes: CareSeverityEngine.scoreCeilingBytes * 10)
        XCTAssertLessThanOrEqual(severity(huge, context(usedRatio: 0.99)).score, 1.0)
    }

    func test_countFindings_scoreSaturatesAtNotableCount() {
        let notable = CareSeverityEngine.notableCount(for: .appUpdates)
        let saturated = severity(updates(notable)).score
        XCTAssertEqual(saturated, CareSeverityEngine.magnitudeWeight, accuracy: 0.0001)
        XCTAssertEqual(severity(updates(notable * 3)).score, saturated, accuracy: 0.0001)
    }

    func test_countFindings_scoreRisesWithCount_belowSaturation() {
        XCTAssertGreaterThan(severity(updates(10)).score, severity(updates(2)).score)
    }

    func test_notableCount_isPositive_forEveryKind() {
        for kind in CareFinding.Kind.allCases {
            XCTAssertGreaterThan(CareSeverityEngine.notableCount(for: kind), 0, "\(kind) needs a saturation point")
        }
    }

    // MARK: - Signals

    func test_magnitudeSignal_firesOnlyForLargeFindings() {
        XCTAssertTrue(severity(junk(bytes: 90_000_000_000)).signals.contains(.magnitude))
        XCTAssertFalse(severity(junk(bytes: 10_000_000)).signals.contains(.magnitude))
    }

    // MARK: - Regrowth

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func receipt(kind: CareFinding.Kind, itemsProcessed: Int, daysAgo: Double) -> CareReceipt {
        CareReceipt(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            lines: [CareReceiptLine(kind: kind, itemsProcessed: itemsProcessed, bytesFreed: 0, outcome: .success)]
        )
    }

    private func history(_ receipts: [CareReceipt]) -> CareSeverityContext {
        CareSeverityContext(health: nil, receipts: receipts, now: now)
    }

    private func installers(_ count: Int, bytes: Int64 = 0) -> CareFinding {
        let files = (0..<count).map { index in
            InstallationFile(
                url: URL(fileURLWithPath: "/Downloads/app\(index).dmg"),
                name: "app\(index).dmg",
                sizeBytes: bytes,
                kind: .diskImage
            )
        }
        return CareFinding(kind: .installers, payload: .installers(files))
    }

    func test_regrowth_firesWithinTheWindow_atHalfTheClearedCount() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 5)])
        let result = severity(installers(5), ctx)
        XCTAssertTrue(result.signals.contains { if case .regrowth = $0 { return true } else { return false } })
    }

    func test_regrowth_doesNotFire_belowHalfTheClearedCount() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 5)])
        XCTAssertFalse(severity(installers(4), ctx).signals.contains { if case .regrowth = $0 { return true } else { return false } })
    }

    func test_regrowth_doesNotFire_pastTheWindow() {
        let stale = CareSeverityEngine.regrowthWindowDays + 1
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: stale)])
        XCTAssertNil(CareSeverityEngine.regrowth(for: installers(10), context: ctx))
    }

    func test_regrowth_reportsTheMostRecentClearingReceipt() {
        let ctx = history([
            receipt(kind: .installers, itemsProcessed: 10, daysAgo: 20),
            receipt(kind: .installers, itemsProcessed: 10, daysAgo: 3),
        ])
        XCTAssertEqual(
            CareSeverityEngine.regrowth(for: installers(10), context: ctx),
            now.addingTimeInterval(-3 * 86_400)
        )
    }

    func test_regrowth_ignoresReceiptLinesThatProcessedNothing() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 0, daysAgo: 3)])
        XCTAssertNil(CareSeverityEngine.regrowth(for: installers(10), context: ctx))
    }

    func test_regrowth_ignoresOtherKinds() {
        let ctx = history([receipt(kind: .downloads, itemsProcessed: 10, daysAgo: 3)])
        XCTAssertNil(CareSeverityEngine.regrowth(for: installers(10), context: ctx))
    }

    func test_regrowth_raisesScore_forAWhitelistedKind() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 1)])
        XCTAssertGreaterThan(severity(installers(10), ctx).score, severity(installers(10)).score)
    }

    func test_regrowth_scoreDecays_asTheReceiptAges() {
        let fresh = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 1)])
        let old = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 25)])
        XCTAssertGreaterThan(severity(installers(10), fresh).score, severity(installers(10), old).score)
    }

    func test_regrowth_onJunk_reportsTheSignal_butScoresZero() {
        // macOS rebuilding its own caches is the system working as designed —
        // worth saying, never worth escalating.
        let ctx = history([receipt(kind: .junkCleanup, itemsProcessed: 100, daysAgo: 1)])
        let regrown = CareFinding(
            kind: .junkCleanup,
            payload: .junk(ScanResult(items: (0..<100).map { file("/cache/\($0)", size: 1_000) }))
        )
        XCTAssertTrue(severity(regrown, ctx).signals.contains { if case .regrowth = $0 { return true } else { return false } })
        XCTAssertEqual(severity(regrown, ctx).score, severity(regrown).score, accuracy: 0.0001)
    }

    func test_regrowthScoringKinds_areAllTrashRecoverable() {
        // Every kind that regrowth escalates must be one the user can undo.
        for kind in CareSeverityEngine.regrowthScoringKinds {
            XCTAssertTrue(kind.movesToTrash, "\(kind) escalates on regrowth but isn't recoverable")
        }
    }

    // MARK: - Determinism

    func test_severity_isDeterministic_forTheSameInputs() {
        let finding = junk(bytes: 3_000_000_000)
        let ctx = context(usedRatio: 0.9)
        XCTAssertEqual(severity(finding, ctx), severity(finding, ctx))
    }
}
