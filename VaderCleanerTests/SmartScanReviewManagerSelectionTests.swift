// SmartScanReviewManagerSelectionTests.swift
// Verifies the manager's uniform-selection fast path: a category tally that reports everything (or nothing) selected answers every row checkbox in O(1), and only a mixed tally falls back to the per-row check.

import XCTest
@testable import VaderCleaner

final class SmartScanReviewManagerSelectionTests: XCTestCase {

    /// Everything in the category selected → every row is checked without a
    /// per-row walk.
    func test_uniformSelection_allSelected_isTrue() {
        XCTAssertEqual(SmartScanReviewManager.uniformSelection(tally: (selected: 5, total: 5)), true)
    }

    /// A tally that over-counts (a stale total racing a selection change) still
    /// reads as fully selected rather than falling back to the slow walk.
    func test_uniformSelection_overCount_isTrue() {
        XCTAssertEqual(SmartScanReviewManager.uniformSelection(tally: (selected: 6, total: 5)), true)
    }

    /// Nothing selected → every row is unchecked without a per-row walk.
    func test_uniformSelection_noneSelected_isFalse() {
        XCTAssertEqual(SmartScanReviewManager.uniformSelection(tally: (selected: 0, total: 5)), false)
    }

    /// A mixed tally can't answer per-row; the caller's check must run.
    func test_uniformSelection_partial_isNil() {
        XCTAssertNil(SmartScanReviewManager.uniformSelection(tally: (selected: 2, total: 5)))
    }

    /// No tally (the small flat managers) or an empty category → no fast path.
    func test_uniformSelection_missingOrEmptyTally_isNil() {
        XCTAssertNil(SmartScanReviewManager.uniformSelection(tally: nil))
        XCTAssertNil(SmartScanReviewManager.uniformSelection(tally: (selected: 0, total: 0)))
    }
}
