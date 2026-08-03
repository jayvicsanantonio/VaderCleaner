// CareDeclineStoreTests.swift
// Tests the persisted record of findings the user keeps passing on: consecutive-decline counting, reset on action, and graceful handling of corrupt stored data.

import XCTest
@testable import VaderCleaner

@MainActor
final class CareDeclineStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "VaderCleanerTests.CareDeclines.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func test_freshStore_countsNothing() {
        let sut = CareDeclineStore(defaults: defaults)
        XCTAssertEqual(sut.declineCount(for: .similarImages), 0)
        XCTAssertTrue(sut.isEmpty)
    }

    func test_decliningAFinding_countsIt() {
        let sut = CareDeclineStore(defaults: defaults)
        sut.record(declined: [.similarImages], accepted: [])
        XCTAssertEqual(sut.declineCount(for: .similarImages), 1)
    }

    func test_decliningRepeatedly_accumulates() {
        let sut = CareDeclineStore(defaults: defaults)
        for _ in 0..<4 { sut.record(declined: [.similarImages], accepted: []) }
        XCTAssertEqual(sut.declineCount(for: .similarImages), 4)
    }

    func test_actingOnAFinding_resetsItsCount() {
        let sut = CareDeclineStore(defaults: defaults)
        for _ in 0..<4 { sut.record(declined: [.similarImages], accepted: []) }
        sut.record(declined: [], accepted: [.similarImages])
        XCTAssertEqual(sut.declineCount(for: .similarImages), 0)
    }

    func test_countsAreIndependentPerKind() {
        let sut = CareDeclineStore(defaults: defaults)
        sut.record(declined: [.similarImages, .downloads], accepted: [])
        sut.record(declined: [.similarImages], accepted: [.downloads])
        XCTAssertEqual(sut.declineCount(for: .similarImages), 2)
        XCTAssertEqual(sut.declineCount(for: .downloads), 0)
    }

    func test_countsSurviveAReload() {
        let sut = CareDeclineStore(defaults: defaults)
        sut.record(declined: [.largeOldFiles], accepted: [])
        sut.record(declined: [.largeOldFiles], accepted: [])
        XCTAssertEqual(CareDeclineStore(defaults: defaults).declineCount(for: .largeOldFiles), 2)
    }

    func test_clear_forgetsEverything() {
        let sut = CareDeclineStore(defaults: defaults)
        sut.record(declined: [.largeOldFiles], accepted: [])
        sut.clear()
        XCTAssertEqual(sut.declineCount(for: .largeOldFiles), 0)
        XCTAssertTrue(sut.isEmpty)
        XCTAssertTrue(CareDeclineStore(defaults: defaults).isEmpty)
    }

    func test_corruptStoredData_degradesToEmpty() {
        defaults.set("not a count table", forKey: "smartScan.declines.counts")
        XCTAssertTrue(CareDeclineStore(defaults: defaults).isEmpty)
    }

    func test_unknownStoredKinds_areIgnored() {
        // A kind removed in a later build must not resurrect as a phantom count.
        defaults.set(["someRetiredKind": 9], forKey: "smartScan.declines.counts")
        let sut = CareDeclineStore(defaults: defaults)
        for kind in CareFinding.Kind.allCases {
            XCTAssertEqual(sut.declineCount(for: kind), 0)
        }
    }

    func test_countTable_exposesOnlyKindsAndCounts() {
        // The record is behavioural, so it must stay free of anything that
        // could identify a file: kind identifiers and integers only.
        let sut = CareDeclineStore(defaults: defaults)
        sut.record(declined: [.similarImages], accepted: [])
        let stored = defaults.dictionary(forKey: "smartScan.declines.counts")
        XCTAssertEqual(stored?.keys.sorted(), ["similarImages"])
        XCTAssertTrue(stored?.values.allSatisfy { $0 is Int } ?? false)
    }
}
