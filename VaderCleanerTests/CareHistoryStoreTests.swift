// CareHistoryStoreTests.swift
// Tests the persisted scan history: last-scan date, cumulative bytes freed, the capped receipt log, and graceful handling of corrupt stored data.

import XCTest
@testable import VaderCleaner

@MainActor
final class CareHistoryStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VaderCleanerTests.CareHistory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func receipt(bytes: Int64, date: Date = Date()) -> CareReceipt {
        CareReceipt(
            date: date,
            lines: [CareReceiptLine(kind: .junkCleanup, itemsProcessed: 3, bytesFreed: bytes, outcome: .success)]
        )
    }

    func test_freshStore_isEmpty() {
        let sut = CareHistoryStore(defaults: defaults)
        XCTAssertNil(sut.lastScanDate)
        XCTAssertEqual(sut.cumulativeBytesFreed, 0)
        XCTAssertTrue(sut.receipts.isEmpty)
        XCTAssertNil(sut.lifetimeFreedLine())
    }

    func test_recordScan_persistsAcrossInstances() {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        CareHistoryStore(defaults: defaults).recordScan(at: date)
        let reloaded = CareHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastScanDate, date)
    }

    func test_recordReceipt_accumulatesBytes_andPersists() {
        let sut = CareHistoryStore(defaults: defaults)
        sut.recordReceipt(receipt(bytes: 1_000))
        sut.recordReceipt(receipt(bytes: 500))
        XCTAssertEqual(sut.cumulativeBytesFreed, 1_500)
        let reloaded = CareHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.cumulativeBytesFreed, 1_500)
        XCTAssertEqual(reloaded.receipts.count, 2)
    }

    func test_receipts_cappedAtLimit_keepingNewest() {
        let sut = CareHistoryStore(defaults: defaults)
        for index in 0..<(CareHistoryStore.maxReceipts + 5) {
            sut.recordReceipt(receipt(bytes: Int64(index), date: Date(timeIntervalSinceReferenceDate: Double(index))))
        }
        XCTAssertEqual(sut.receipts.count, CareHistoryStore.maxReceipts)
        XCTAssertEqual(
            sut.receipts.last?.lines.first?.bytesFreed,
            Int64(CareHistoryStore.maxReceipts + 4),
            "the newest receipt survives the cap"
        )
    }

    func test_lifetimeFreedLine_quotesTheCumulativeTotal() {
        let sut = CareHistoryStore(defaults: defaults)
        sut.recordReceipt(receipt(bytes: 2_300_000_000))
        let line = sut.lifetimeFreedLine()
        XCTAssertNotNil(line)
        XCTAssertTrue(
            line?.contains(CareFindingCopy.formattedBytes(2_300_000_000)) == true,
            "the line quotes the lifetime freed total: \(line ?? "nil")"
        )
    }

    // MARK: - Clearing

    func test_clear_resetsEveryFieldInMemory() {
        let sut = CareHistoryStore(defaults: defaults)
        sut.recordScan(at: Date(timeIntervalSinceReferenceDate: 700_000_000))
        sut.recordReceipt(receipt(bytes: 4_000))

        sut.clear()

        XCTAssertNil(sut.lastScanDate)
        XCTAssertEqual(sut.cumulativeBytesFreed, 0)
        XCTAssertTrue(sut.receipts.isEmpty)
        XCTAssertNil(sut.lifetimeFreedLine())
    }

    func test_clear_removesPersistedValues_soAReloadStaysEmpty() {
        let sut = CareHistoryStore(defaults: defaults)
        sut.recordScan(at: Date(timeIntervalSinceReferenceDate: 700_000_000))
        sut.recordReceipt(receipt(bytes: 4_000))

        sut.clear()

        let reloaded = CareHistoryStore(defaults: defaults)
        XCTAssertNil(reloaded.lastScanDate)
        XCTAssertEqual(reloaded.cumulativeBytesFreed, 0)
        XCTAssertTrue(reloaded.receipts.isEmpty)
    }

    func test_clear_onAFreshStore_isHarmless() {
        let sut = CareHistoryStore(defaults: defaults)
        sut.clear()
        XCTAssertNil(sut.lastScanDate)
        XCTAssertEqual(sut.cumulativeBytesFreed, 0)
        XCTAssertTrue(sut.receipts.isEmpty)
    }

    /// Clearing history must not disturb anything else living in the same
    /// suite — it owns only its three keys.
    func test_clear_leavesUnrelatedDefaultsAlone() {
        defaults.set("keep me", forKey: "preferences.somethingElse")
        let sut = CareHistoryStore(defaults: defaults)
        sut.recordReceipt(receipt(bytes: 10))

        sut.clear()

        XCTAssertEqual(defaults.string(forKey: "preferences.somethingElse"), "keep me")
    }

    func test_recordingAfterClear_startsFromZero() {
        let sut = CareHistoryStore(defaults: defaults)
        sut.recordReceipt(receipt(bytes: 9_000))
        sut.clear()

        sut.recordReceipt(receipt(bytes: 25))

        XCTAssertEqual(sut.cumulativeBytesFreed, 25)
        XCTAssertEqual(sut.receipts.count, 1)
    }

    func test_corruptStoredReceipts_degradeToEmpty() {
        defaults.set("not json".data(using: .utf8), forKey: "smartScan.history.receipts")
        defaults.set(Data([0x01]), forKey: "smartScan.history.receipts")
        let sut = CareHistoryStore(defaults: defaults)
        XCTAssertTrue(sut.receipts.isEmpty)
    }
}
