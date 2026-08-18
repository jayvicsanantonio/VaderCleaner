// CarePlanTests.swift
// Tests that CarePlan aggregates findings and per-unit outcomes correctly: malware-performed detection, finding lookup, and honest failed/skipped unit reporting.

import XCTest
@testable import VaderCleaner

final class CarePlanTests: XCTestCase {

    private func plan(
        findings: [CareFinding] = [],
        health: CareHealthSnapshot? = nil,
        outcomes: [CareScanUnit: CareUnitOutcome]
    ) -> CarePlan {
        CarePlan(
            findings: findings,
            health: health,
            unitOutcomes: outcomes,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 60)
        )
    }

    func test_malwareScanPerformed_onlyWhenMalwareUnitCompleted() {
        XCTAssertTrue(plan(outcomes: [.malware: .completed]).malwareScanPerformed)
        XCTAssertFalse(plan(outcomes: [.malware: .skipped(.clamAVUnavailable)]).malwareScanPerformed)
        XCTAssertFalse(plan(outcomes: [.malware: .failed(message: "boom")]).malwareScanPerformed)
        XCTAssertFalse(plan(outcomes: [:]).malwareScanPerformed)
    }

    func test_findingLookup_byKind() {
        let junk = CareFinding(payload: .junk(ScanResult(items: [])))
        let sut = plan(findings: [junk], outcomes: [:])
        XCTAssertEqual(sut.finding(.junkCleanup), junk)
        XCTAssertNil(sut.finding(.threats))
    }

    func test_failedUnits_listsOnlyFailures_inStableOrder() {
        let sut = plan(outcomes: [
            .systemJunk: .failed(message: "no access"),
            .malware: .completed,
            .duplicates: .failed(message: "boom")
        ])
        XCTAssertEqual(sut.failedUnits, [.systemJunk, .duplicates])
    }

    func test_skippedUnits_listsOnlySkips_inStableOrder() {
        let sut = plan(outcomes: [
            .malware: .skipped(.clamAVUnavailable),
            .browserPrivacy: .skipped(.disabledInSettings),
            .systemJunk: .completed
        ])
        XCTAssertEqual(sut.skippedUnits, [.malware, .browserPrivacy])
    }

    func test_everyCheckFailed_ignoresTheHealthSnapshot() {
        // The snapshot always completes, so a scan whose real checks all failed
        // would otherwise read as a partial success.
        XCTAssertTrue(plan(outcomes: [
            .systemJunk: .failed(message: "no access"),
            .healthSnapshot: .completed
        ]).everyCheckFailed)
        XCTAssertTrue(plan(outcomes: [.healthSnapshot: .completed]).everyCheckFailed, "nothing was checked")
    }

    func test_everyCheckFailed_falseWhenAnyRealUnitCompleted() {
        XCTAssertFalse(plan(outcomes: [
            .systemJunk: .completed,
            .malware: .failed(message: "broken"),
            .healthSnapshot: .completed
        ]).everyCheckFailed)
    }

    // MARK: - Merging a targeted re-scan

    private func file(_ path: String, size: Int64) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
    }

    private func junkFinding(_ paths: [String]) -> CareFinding {
        CareFinding(payload: .junk(ScanResult(items: paths.map { file($0, size: 10) })))
    }

    private var largeFilesFinding: CareFinding {
        CareFinding(payload: .largeOldFiles([file("/Movies/huge.mov", size: 9_000)]))
    }

    func test_merging_replacesFindingsForTheRescannedUnits() {
        let before = plan(
            findings: [junkFinding(["/cache/a", "/cache/b"]), largeFilesFinding],
            outcomes: [.systemJunk: .completed, .largeOldFiles: .completed]
        )
        let refreshed = plan(
            findings: [junkFinding(["/cache/regrown"])],
            outcomes: [.systemJunk: .completed]
        )

        let merged = before.merging(refreshed, for: [.systemJunk])

        guard case .junk(let result)? = merged.finding(.junkCleanup)?.payload else {
            return XCTFail("expected a junk finding")
        }
        XCTAssertEqual(result.items.map(\.url.path), ["/cache/regrown"])
    }

    func test_merging_carriesUntouchedFindingsForward() {
        let before = plan(
            findings: [junkFinding(["/cache/a"]), largeFilesFinding],
            outcomes: [.systemJunk: .completed, .largeOldFiles: .completed]
        )
        let refreshed = plan(findings: [], outcomes: [.systemJunk: .completed])

        let merged = before.merging(refreshed, for: [.systemJunk])

        XCTAssertEqual(
            merged.finding(.largeOldFiles), largeFilesFinding,
            "a finding the run never touched is still accurate and must survive"
        )
    }

    /// The point of the re-scan: work that is genuinely gone disappears from the
    /// feed rather than lingering as a stale card.
    func test_merging_dropsARescannedFindingThatCameBackEmpty() {
        let before = plan(
            findings: [junkFinding(["/cache/a"]), largeFilesFinding],
            outcomes: [.systemJunk: .completed, .largeOldFiles: .completed]
        )
        let refreshed = plan(findings: [], outcomes: [.systemJunk: .completed])

        let merged = before.merging(refreshed, for: [.systemJunk])

        XCTAssertNil(merged.finding(.junkCleanup))
    }

    func test_merging_takesOutcomesForRescannedUnitsAndKeepsTheRest() {
        let before = plan(outcomes: [.systemJunk: .completed, .malware: .completed])
        let refreshed = plan(outcomes: [.systemJunk: .failed(message: "no access")])

        let merged = before.merging(refreshed, for: [.systemJunk])

        XCTAssertEqual(merged.unitOutcomes[.systemJunk], .failed(message: "no access"))
        XCTAssertEqual(merged.unitOutcomes[.malware], .completed, "an untouched unit keeps its outcome")
    }

    /// Health rides along on every re-scan because a cleanup changes free space,
    /// which is the number the verdict hero reads.
    func test_merging_takesFreshHealthWhenTheRescanCapturedIt() {
        let stale = CareHealthSnapshot(
            disk: DiskStats(usedBytes: 90, totalBytes: 100),
            memoryPressure: .nominal,
            smart: .good,
            battery: .absent
        )
        let fresh = CareHealthSnapshot(
            disk: DiskStats(usedBytes: 60, totalBytes: 100),
            memoryPressure: .nominal,
            smart: .good,
            battery: .absent
        )
        let before = plan(health: stale, outcomes: [.systemJunk: .completed])
        let refreshed = plan(health: fresh, outcomes: [.systemJunk: .completed])

        XCTAssertEqual(before.merging(refreshed, for: [.systemJunk]).health, fresh)
    }

    func test_merging_keepsTheEarlierHealthWhenTheRescanHadNone() {
        let stale = CareHealthSnapshot(
            disk: DiskStats(usedBytes: 90, totalBytes: 100),
            memoryPressure: .nominal,
            smart: .good,
            battery: .absent
        )
        let before = plan(health: stale, outcomes: [.systemJunk: .completed])
        let refreshed = plan(health: nil, outcomes: [.systemJunk: .completed])

        XCTAssertEqual(before.merging(refreshed, for: [.systemJunk]).health, stale)
    }

    /// The merged plan describes one span of checking: it began when the user's
    /// scan began and is current as of the re-scan.
    func test_merging_spansTheOriginalScanThroughTheRescan() {
        let before = plan(outcomes: [:])
        let refreshed = CarePlan(
            findings: [],
            health: nil,
            unitOutcomes: [:],
            startedAt: Date(timeIntervalSinceReferenceDate: 600),
            finishedAt: Date(timeIntervalSinceReferenceDate: 660)
        )

        let merged = before.merging(refreshed, for: [.systemJunk])

        XCTAssertEqual(merged.startedAt, before.startedAt)
        XCTAssertEqual(merged.finishedAt, refreshed.finishedAt)
    }
}
