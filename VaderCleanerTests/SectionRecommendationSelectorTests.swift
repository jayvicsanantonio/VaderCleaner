// SectionRecommendationSelectorTests.swift
// Pins the shared tile ranking core: urgency outranks size, size breaks ties, ties are stable, the count is capped at four, and reassurance backfills to the floor of two without displacing real findings.

import XCTest
@testable import VaderCleaner

final class SectionRecommendationSelectorTests: XCTestCase {

    /// Builds a real (non-reassurance) candidate wrapping a String payload so the
    /// tests can assert selection order by identity.
    private func tile(_ payload: String,
                      _ urgency: RecommendationUrgency,
                      _ bytes: Int64) -> RankedTile<String> {
        RankedTile(payload: payload, urgency: urgency, reclaimableBytes: bytes)
    }

    // MARK: - Ranking

    /// Urgency dominates size: a zero-byte safety finding must lead a huge
    /// space finding so an ordinary person sees the important thing first.
    func test_urgency_outranksBytes() {
        let selected = SectionRecommendationSelector.select(
            real: [
                tile("space", .space, 100_000_000_000),
                tile("critical", .critical, 0),
            ],
            reassurance: []
        )
        XCTAssertEqual(selected, ["critical", "space"])
    }

    /// Within one urgency level the larger reclaimable size leads.
    func test_withinUrgency_largerBytesLead() {
        let selected = SectionRecommendationSelector.select(
            real: [
                tile("small", .space, 1_000),
                tile("large", .space, 9_000),
                tile("medium", .space, 5_000),
            ],
            reassurance: []
        )
        XCTAssertEqual(selected, ["large", "medium", "small"])
    }

    /// Equal urgency and equal size preserve the input order — the sort must be
    /// stable so the layout never reshuffles between renders of identical data.
    func test_equalRank_keepsInputOrder() {
        let selected = SectionRecommendationSelector.select(
            real: [
                tile("first", .space, 4_000),
                tile("second", .space, 4_000),
                tile("third", .space, 4_000),
            ],
            reassurance: []
        )
        XCTAssertEqual(selected, ["first", "second", "third"])
    }

    // MARK: - Cap

    /// Never more than four tiles: the lowest-ranked real findings are dropped.
    func test_capsAtFour_droppingLowestRanked() {
        let selected = SectionRecommendationSelector.select(
            real: [
                tile("a", .space, 5),
                tile("b", .space, 4),
                tile("c", .space, 3),
                tile("d", .space, 2),
                tile("e", .space, 1),
            ],
            reassurance: []
        )
        XCTAssertEqual(selected, ["a", "b", "c", "d"])
    }

    // MARK: - Floor

    /// A single real finding is topped up to two with the first reassurance tile.
    func test_oneReal_backfillsToTwo() {
        let selected = SectionRecommendationSelector.select(
            real: [tile("real", .space, 1_000)],
            reassurance: [
                tile("calm1", .reassurance, 0),
                tile("calm2", .reassurance, 0),
            ]
        )
        XCTAssertEqual(selected, ["real", "calm1"])
    }

    /// No real findings still yields two distinct reassurance tiles, in pool order.
    func test_noReal_showsTwoDistinctReassurance() {
        let selected = SectionRecommendationSelector.select(
            real: [],
            reassurance: [
                tile("calm1", .reassurance, 0),
                tile("calm2", .reassurance, 0),
                tile("calm3", .reassurance, 0),
            ]
        )
        XCTAssertEqual(selected, ["calm1", "calm2"])
    }

    /// Reassurance is only filler: two or more real findings suppress it entirely.
    func test_reassurance_neverDisplacesReal() {
        let selected = SectionRecommendationSelector.select(
            real: [
                tile("r1", .space, 2_000),
                tile("r2", .space, 1_000),
            ],
            reassurance: [tile("calm", .reassurance, 0)]
        )
        XCTAssertEqual(selected, ["r1", "r2"])
    }

    /// The floor is best-effort: with too few reassurance tiles the result can
    /// dip below two rather than repeating a card.
    func test_floor_isBestEffort_whenReassuranceExhausted() {
        let selected = SectionRecommendationSelector.select(
            real: [],
            reassurance: [tile("only", .reassurance, 0)]
        )
        XCTAssertEqual(selected, ["only"])
    }
}
