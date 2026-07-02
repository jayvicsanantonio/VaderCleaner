// MyClutterTileKindTests.swift
// Pins how the My Clutter dashboard turns its four clutter categories into the ranked 2–4 cards it shows: only categories with findings appear, largest reclaimable size leads, and a near-empty scan backfills with reassurance.

import XCTest
@testable import VaderCleaner

final class MyClutterTileKindTests: XCTestCase {

    private let none = (count: 0, bytes: Int64(0))

    /// Only categories that actually found files appear, ranked by reclaimable
    /// size (largest first).
    func test_recommended_showsOnlyFoundCategories_rankedBySize() {
        let tiles = MyClutterTileKind.recommended(
            duplicates: (count: 3, bytes: 500),
            similar: none,
            largeOld: (count: 2, bytes: 9_000),
            downloads: (count: 1, bytes: 3_000)
        )

        XCTAssertEqual(tiles, [.largeOld, .downloads, .duplicates])
    }

    /// A category with a count but a rounding-to-zero byte total still appears —
    /// presence is gated on the count, not the size.
    func test_recommended_gatesOnCount_notBytes() {
        let tiles = MyClutterTileKind.recommended(
            duplicates: (count: 1, bytes: 0),
            similar: (count: 5, bytes: 10),
            largeOld: none,
            downloads: none
        )

        XCTAssertEqual(tiles, [.similar, .duplicates])
    }

    /// A single found category is topped up to two cards with a reassurance
    /// backfill so the grid never shows a lone card.
    func test_recommended_backfillsReassuranceBelowFloor() {
        let tiles = MyClutterTileKind.recommended(
            duplicates: (count: 4, bytes: 1_000),
            similar: none, largeOld: none, downloads: none
        )

        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles.first, .duplicates)
        guard case .reassurance = tiles[1] else {
            return XCTFail("second tile should be a reassurance backfill")
        }
    }

    /// An empty scan still shows two distinct reassurance cards.
    func test_recommended_emptyScan_showsTwoReassurance() {
        let tiles = MyClutterTileKind.recommended(
            duplicates: none, similar: none, largeOld: none, downloads: none
        )

        XCTAssertEqual(tiles.count, 2)
        XCTAssertNotEqual(tiles[0], tiles[1])
        for tile in tiles {
            guard case .reassurance = tile else {
                return XCTFail("empty scan should show only reassurance cards")
            }
        }
    }
}
