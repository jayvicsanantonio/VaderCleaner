// CareSeverityEngineTests.swift
// Tests the pure severity derivation: kind-derived base tier, disk-pressure escalation and boost, regrowth and decline signals, and the score that orders findings within a tier.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct CareSeverityEngineTests {

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
        CareFinding(payload: .junk(ScanResult(items: [file("/cache", size: bytes)])))
    }

    private func largeOld(bytes: Int64) -> CareFinding {
        CareFinding(payload: .largeOldFiles([file("/big", size: bytes, category: .largeFile)]))
    }

    private func lowDisk(usedRatio: Double) -> CareFinding {
        CareFinding(payload: .lowDiskSpace(DiskStats(usedBytes: UInt64(usedRatio * 1_000), totalBytes: 1_000))
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
        return CareFinding(payload: .appUpdates(list))
    }

    private func severity(_ finding: CareFinding, _ context: CareSeverityContext = .none) -> CareSeverity {
        CareSeverityEngine.severity(for: finding, context: context)
    }

    // MARK: - Base tier

    @Test
    func baseTier_matchesTheKindsUrgency_withEmptyContext() {
        for finding in [junk(bytes: 5_000), largeOld(bytes: 5_000), updates(3), lowDisk(usedRatio: 0.5)] {
            #expect(
                severity(finding).urgency == finding.urgency,
                "an empty context must never move \(finding.kind) off its kind-derived tier"
            )
        }
    }

    @Test
    func appUpdates_stayAttention_atEveryCount() {
        for count in [1, 20, 200] {
            #expect(severity(updates(count), context(usedRatio: 0.99)).urgency == .attention)
        }
    }

    // MARK: - Disk-pressure escalation

    @Test
    func lowDiskSpace_at99Percent_escalatesToCritical() {
        let result = severity(lowDisk(usedRatio: 0.99), context(usedRatio: 0.99))
        #expect(result.urgency == .critical)
        #expect(result.signals.contains(.diskPressure))
    }

    @Test
    func lowDiskSpace_at91Percent_staysAttention() {
        #expect(severity(lowDisk(usedRatio: 0.91), context(usedRatio: 0.91)).urgency == .attention)
    }

    @Test
    func lowDiskSpace_readsItsOwnPayload_notTheContext() {
        // The card describes a specific volume; its escalation must follow that
        // payload even when the health snapshot is missing.
        #expect(severity(lowDisk(usedRatio: 0.99)).urgency == .critical)
    }

    @Test
    func diskThresholds_areTheHealthMonitorConstants_notCopies() {
        #expect(CareSeverityEngine.diskCriticalThreshold == HealthMonitorViewModel.diskCriticalThreshold)
        #expect(CareSeverityEngine.diskWarningThreshold == HealthMonitorViewModel.diskWarningThreshold)
    }

    // MARK: - Disk-pressure boost

    @Test
    func largePreApprovedFinding_underDiskPressure_outscoresItsQuietSelf() {
        let big = junk(bytes: 8_000_000_000)
        #expect(severity(big, context(usedRatio: 0.85)).score > severity(big, context(usedRatio: 0.20)).score)
        #expect(severity(big, context(usedRatio: 0.85)).signals.contains(.diskPressure))
    }

    @Test
    func optInFinding_underDiskPressure_getsNoBoost() {
        // The user's own files are their call — pressure must not make the app
        // push harder on data it isn't allowed to remove unattended.
        let big = largeOld(bytes: 8_000_000_000)
        #expect(abs(severity(big, context(usedRatio: 0.85)).score - severity(big, context(usedRatio: 0.20)).score) <= 0.0001)
        #expect(!severity(big, context(usedRatio: 0.85)).signals.contains(.diskPressure))
    }

    @Test
    func findingBelowTheBoostFloor_underDiskPressure_getsNoBoost() {
        let small = junk(bytes: 500_000_000)
        #expect(
            abs(severity(small, context(usedRatio: 0.85)).score - severity(small, context(usedRatio: 0.20)).score) <= 0.0001
        )
    }

    @Test
    func diskPressureBoost_needsPressure() {
        let big = junk(bytes: 8_000_000_000)
        #expect(!severity(big, context(usedRatio: 0.50)).signals.contains(.diskPressure))
    }

    // MARK: - Score

    @Test
    func score_isMonotonicInBytes_forSizedFindings() {
        let sizes: [Int64] = [1_000, 50_000_000, 900_000_000, 6_000_000_000, 40_000_000_000]
        let scores = sizes.map { severity(junk(bytes: $0)).score }
        #expect(scores == scores.sorted(), "score must never fall as bytes rise")
    }

    @Test
    func score_separatesLargeFindings_moreThanSmallOnes() {
        // The point of log scaling: 40 GB vs 6 GB is a real difference worth
        // ordering on; 200 MB vs 100 MB is noise that should not dominate.
        let bigGap = severity(junk(bytes: 40_000_000_000)).score - severity(junk(bytes: 6_000_000_000)).score
        let smallGap = severity(junk(bytes: 200_000_000)).score - severity(junk(bytes: 100_000_000)).score
        #expect(bigGap > smallGap)
    }

    @Test
    func score_isClampedToOne_aboveTheCeiling() {
        let huge = junk(bytes: CareSeverityEngine.scoreCeilingBytes * 10)
        #expect(severity(huge, context(usedRatio: 0.99)).score <= 1.0)
    }

    @Test
    func countFindings_scoreSaturatesAtNotableCount() {
        let notable = CareSeverityEngine.notableCount(for: .appUpdates)
        let saturated = severity(updates(notable)).score
        #expect(abs(saturated - CareSeverityEngine.magnitudeWeight) <= 0.0001)
        #expect(abs(severity(updates(notable * 3)).score - saturated) <= 0.0001)
    }

    @Test
    func countFindings_scoreRisesWithCount_belowSaturation() {
        #expect(severity(updates(10)).score > severity(updates(2)).score)
    }

    @Test
    func notableCount_isPositive_forEveryKind() {
        for kind in CareFinding.Kind.allCases {
            #expect(CareSeverityEngine.notableCount(for: kind) > 0, "\(kind) needs a saturation point")
        }
    }

    // MARK: - Signals

    @Test
    func size_neverRaisesASignal_howeverLargeTheFinding() {
        // Magnitude orders the feed; it never speaks. The card already prints
        // the size, so a note restating it would be noise on every big finding.
        #expect(severity(junk(bytes: 90_000_000_000)).signals.isEmpty)
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
        return CareFinding(payload: .installers(files))
    }

    @Test
    func regrowth_firesWithinTheWindow_atHalfTheClearedCount() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 5)])
        let result = severity(installers(5), ctx)
        #expect(result.signals.contains { if case .regrowth = $0 { return true } else { return false } })
    }

    @Test
    func regrowth_doesNotFire_belowHalfTheClearedCount() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 5)])
        #expect(!severity(installers(4), ctx).signals.contains { if case .regrowth = $0 { return true } else { return false } })
    }

    @Test
    func regrowth_doesNotFire_pastTheWindow() {
        let stale = CareSeverityEngine.regrowthWindowDays + 1
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: stale)])
        #expect(CareSeverityEngine.regrowth(for: installers(10), context: ctx) == nil)
    }

    @Test
    func regrowth_reportsTheMostRecentClearingReceipt() {
        let ctx = history([
            receipt(kind: .installers, itemsProcessed: 10, daysAgo: 20),
            receipt(kind: .installers, itemsProcessed: 10, daysAgo: 3),
        ])
        #expect(
            CareSeverityEngine.regrowth(for: installers(10), context: ctx) == now.addingTimeInterval(-3 * 86_400)
        )
    }

    @Test
    func regrowth_ignoresReceiptLinesThatProcessedNothing() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 0, daysAgo: 3)])
        #expect(CareSeverityEngine.regrowth(for: installers(10), context: ctx) == nil)
    }

    @Test
    func regrowth_ignoresOtherKinds() {
        let ctx = history([receipt(kind: .downloads, itemsProcessed: 10, daysAgo: 3)])
        #expect(CareSeverityEngine.regrowth(for: installers(10), context: ctx) == nil)
    }

    @Test
    func regrowth_raisesScore_forAWhitelistedKind() {
        let ctx = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 1)])
        #expect(severity(installers(10), ctx).score > severity(installers(10)).score)
    }

    @Test
    func regrowth_scoreDecays_asTheReceiptAges() {
        let fresh = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 1)])
        let old = history([receipt(kind: .installers, itemsProcessed: 10, daysAgo: 25)])
        #expect(severity(installers(10), fresh).score > severity(installers(10), old).score)
    }

    @Test
    func regrowth_onJunk_isNeitherReportedNorScored() {
        // macOS rebuilding its own caches is the system working as designed.
        // Reporting it as "back since your last cleanup" would frame correct
        // behaviour as a complaint.
        let ctx = history([receipt(kind: .junkCleanup, itemsProcessed: 100, daysAgo: 1)])
        let regrown = CareFinding(payload: .junk(ScanResult(items: (0..<100).map { file("/cache/\($0)", size: 1_000) }))
        )
        #expect(!hasRegrowthSignal(severity(regrown, ctx)))
        #expect(abs(severity(regrown, ctx).score - severity(regrown).score) <= 0.0001)
    }

    @Test
    func regrowth_onRoutineMaintenance_isNeitherReportedNorScored() {
        // A tune-up that never came due again would not be routine. Same
        // category error as junk, and the same answer.
        let ctx = history([receipt(kind: .maintenanceDue, itemsProcessed: 2, daysAgo: 1)])
        let due = CareFinding(payload: .maintenanceDue(taskIDs: ["flushDNS", "speedUpMail"]))
        #expect(!hasRegrowthSignal(severity(due, ctx)))
        #expect(abs(severity(due, ctx).score - severity(due).score) <= 0.0001)
    }

    @Test
    func recurringByDesignKinds_areExcludedFromRegrowth() {
        // The carve-out is the rule, not an accident of the current list.
        #expect(!CareSeverityEngine.regrowthKinds.contains(.junkCleanup))
        #expect(!CareSeverityEngine.regrowthKinds.contains(.maintenanceDue))
    }

    @Test
    func regrowthKinds_areAllTrashRecoverable() {
        // Every kind that regrowth escalates must be one the user can undo.
        for kind in CareSeverityEngine.regrowthKinds {
            #expect(kind.movesToTrash, "\(kind) escalates on regrowth but isn't recoverable")
        }
    }

    private func hasRegrowthSignal(_ severity: CareSeverity) -> Bool {
        severity.signals.contains { if case .regrowth = $0 { return true } else { return false } }
    }

    // MARK: - Declines

    private func declined(_ counts: [CareFinding.Kind: Int]) -> CareSeverityContext {
        CareSeverityContext(health: nil, declines: counts)
    }

    private func similarImages(bytes: Int64) -> CareFinding {
        let group = SimilarImageGroup(files: [
            file("/Pictures/a.jpg", size: bytes, category: .largeFile),
            file("/Pictures/b.jpg", size: bytes, category: .largeFile),
        ])
        return CareFinding(payload: .similarImages([group]))
    }

    @Test
    func decliningBelowTheThreshold_changesNothing() {
        let finding = similarImages(bytes: 2_000_000_000)
        let below = CareSeverityEngine.declineThreshold - 1
        #expect(
            abs(severity(finding, declined([.similarImages: below])).score - severity(finding).score) <= 0.0001
        )
    }

    @Test
    func decliningAtTheThreshold_dampensTheScore() {
        let finding = similarImages(bytes: 2_000_000_000)
        #expect(
            severity(finding, declined([.similarImages: CareSeverityEngine.declineThreshold])).score
                < severity(finding).score
        )
    }

    @Test
    func dampeningDeepens_withMoreDeclines() {
        let finding = similarImages(bytes: 2_000_000_000)
        let three = severity(finding, declined([.similarImages: 3])).score
        let five = severity(finding, declined([.similarImages: 5])).score
        #expect(five < three)
    }

    @Test
    func dampening_neverFallsBelowTheFloor() {
        let finding = similarImages(bytes: 2_000_000_000)
        let quiet = severity(finding).score
        let hammered = severity(finding, declined([.similarImages: 500])).score
        #expect(hammered >= quiet * CareSeverityEngine.declineDampingFloor - 0.0001)
    }

    @Test
    func declines_neverDampenPreApprovedFindings() {
        // Junk, duplicates, updates, maintenance — hygiene the app vouches for.
        // Passing on it once is not a reason to stop mentioning it.
        let finding = junk(bytes: 8_000_000_000)
        #expect(
            abs(severity(finding, declined([.junkCleanup: 50])).score - severity(finding).score) <= 0.0001
        )
    }

    @Test
    func declines_neverQuietThreats() {
        let threat = CareFinding(payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")])
        )
        let result = severity(threat, declined([.threats: 500]))
        #expect(result.urgency == .critical)
        #expect(abs(result.score - severity(threat).score) <= 0.0001)
    }

    @Test
    func declines_neverChangeTheTier() {
        let finding = similarImages(bytes: 2_000_000_000)
        #expect(severity(finding, declined([.similarImages: 500])).urgency == finding.urgency)
    }

    @Test
    func decliningReportsTheSignal_onlyOnceDampeningStarts() {
        let finding = similarImages(bytes: 2_000_000_000)
        let below = CareSeverityEngine.declineThreshold - 1
        #expect(!hasDeclinedSignal(severity(finding, declined([.similarImages: below]))))
        #expect(hasDeclinedSignal(severity(finding, declined([.similarImages: CareSeverityEngine.declineThreshold]))))
    }

    @Test
    func declinedFinding_stillOutranksASmallerOne() {
        // Dampening lowers a card; it must not bury a genuinely bigger finding
        // beneath a trivial one.
        let bigDeclined = severity(similarImages(bytes: 40_000_000_000), declined([.similarImages: 500])).score
        let tinyQuiet = severity(similarImages(bytes: 1_000)).score
        #expect(bigDeclined > tinyQuiet)
    }

    private func hasDeclinedSignal(_ severity: CareSeverity) -> Bool {
        severity.signals.contains { if case .declined = $0 { return true } else { return false } }
    }

    // MARK: - Determinism

    @Test
    func severity_isDeterministic_forTheSameInputs() {
        let finding = junk(bytes: 3_000_000_000)
        let ctx = context(usedRatio: 0.9)
        #expect(severity(finding, ctx) == severity(finding, ctx))
    }
}
