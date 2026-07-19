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
        let junk = CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [])))
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
}
