// TreemapLayoutTests.swift
// Locks the squarified treemap layout's invariants: bounds containment, non-overlap, area proportionality, the squarified aspect-ratio property versus naive slicing, and the empty / single-item / zero-weight edge cases.

import XCTest
import CoreGraphics
@testable import VaderCleaner

/// Unit tests for `TreemapLayout`. The layout is a pure value type with no
/// dependence on `DiskNode`, so these tests use lightweight `(Int, Double)`
/// fixtures. The squarified-quality test is the critical one — without it
/// a buggy slice-and-dice implementation would still pass the non-overlap
/// and proportionality assertions.
final class TreemapLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - Invariants

    /// Every laid-out tile must sit inside the supplied bounds. Without this
    /// guarantee, the treemap could draw outside its `GeometryReader` parent
    /// and clip into neighbouring UI.
    func test_layout_keepsAllRectanglesWithinBounds() {
        let items = uniformItems(count: 8)
        let result = TreemapLayout.layout(items: items, in: bounds)

        let eps: CGFloat = 0.5
        for tile in result {
            XCTAssertGreaterThanOrEqual(tile.rect.minX, bounds.minX - eps,
                                        "Tile \(tile.rect) extends left of bounds")
            XCTAssertGreaterThanOrEqual(tile.rect.minY, bounds.minY - eps,
                                        "Tile \(tile.rect) extends above bounds")
            XCTAssertLessThanOrEqual(tile.rect.maxX, bounds.maxX + eps,
                                     "Tile \(tile.rect) extends right of bounds")
            XCTAssertLessThanOrEqual(tile.rect.maxY, bounds.maxY + eps,
                                     "Tile \(tile.rect) extends below bounds")
        }
    }

    /// No two tiles may overlap. Tile order in the output is implementation-
    /// defined (the squarified algorithm sorts internally), so the test
    /// compares every pair.
    func test_layout_producesNonOverlappingRectangles() {
        let items = mixedItems()
        let result = TreemapLayout.layout(items: items, in: bounds)

        for i in 0..<result.count {
            for j in (i + 1)..<result.count {
                let a = result[i].rect
                let b = result[j].rect
                let overlap = a.intersection(b)
                XCTAssertTrue(
                    overlap.isEmpty || overlap.width < 0.5 || overlap.height < 0.5,
                    "Tiles \(a) and \(b) overlap by \(overlap)"
                )
            }
        }
    }

    /// The sum of tile areas must approximate the bounds' area — the squarified
    /// algorithm is meant to fill the rectangle, not leave gaps. We allow a
    /// 1% slack for floating-point drift across the recursive strip splits.
    func test_layout_sizesRectanglesProportionallyToWeights() {
        let items = mixedItems()
        let result = TreemapLayout.layout(items: items, in: bounds)

        let totalArea = result.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        let boundsArea = Double(bounds.width * bounds.height)
        XCTAssertEqual(totalArea, boundsArea, accuracy: boundsArea * 0.01,
                       "Total tile area must approximate the bounds area")

        // Ratio between any two tile areas must approximate the ratio between
        // their input weights. Pick the two largest items so the comparison is
        // robust to floating-point noise in the very smallest tiles.
        let totalWeight = items.reduce(0.0) { $0 + $1.weight }
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.rect) })
        for item in items {
            let rect = byID[item.id]
            XCTAssertNotNil(rect, "Missing tile for id \(item.id)")
            let area = Double((rect?.width ?? 0) * (rect?.height ?? 0))
            let expected = item.weight / totalWeight * boundsArea
            XCTAssertEqual(area, expected, accuracy: boundsArea * 0.01,
                           "Tile for id \(item.id) has area \(area), expected ~\(expected)")
        }
    }

    /// **The squarified property.** Naive slice-and-dice produces stripes
    /// whose worst aspect ratio degrades linearly with the input size; the
    /// squarified algorithm keeps every tile near-square. For 10 equal
    /// weights in a 400×300 bounds, naive striping yields tiles of either
    /// 40×300 (ratio 7.5) or 400×30 (ratio 13.3), so a worst-case ratio
    /// gate of 5 cleanly distinguishes the two algorithms.
    func test_layout_keepsTilesNearSquare_versusNaiveSlicing() {
        let items = uniformItems(count: 10)
        let result = TreemapLayout.layout(items: items, in: bounds)

        let worst = result.map { tile -> Double in
            let w = max(Double(tile.rect.width), 0.001)
            let h = max(Double(tile.rect.height), 0.001)
            return max(w / h, h / w)
        }.max() ?? .infinity

        XCTAssertLessThan(worst, 5.0,
                          "Squarified layout should keep tiles near-square; worst ratio \(worst)")
    }

    // MARK: - Edge cases

    /// Empty input → empty output. SwiftUI binds the layout result via
    /// `ForEach`, so the empty case must be a valid array (not nil) so the
    /// view simply renders nothing.
    func test_layout_returnsEmptyForEmptyInput() {
        let result = TreemapLayout.layout(items: [(id: Int, weight: Double)](), in: bounds)
        XCTAssertEqual(result.count, 0)
    }

    /// Single item must occupy the full bounds. Without this, drilling into
    /// a folder with one subfolder would render a tiny tile floating inside
    /// otherwise-empty bounds.
    func test_layout_givesFullBoundsToSingleItem() {
        let result = TreemapLayout.layout(items: [(id: 1, weight: 100.0)], in: bounds)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].rect.width, bounds.width, accuracy: 0.01)
        XCTAssertEqual(result[0].rect.height, bounds.height, accuracy: 0.01)
    }

    /// All-zero weights must not divide-by-zero. The empty-directory case
    /// triggers this: every child is an empty file. The contract is that
    /// each item gets a zero-area placeholder so SwiftUI's `ForEach` still
    /// has a stable id-keyed list.
    func test_layout_handlesZeroWeightsWithoutCrashing() {
        let items = [
            (id: 1, weight: 0.0),
            (id: 2, weight: 0.0),
            (id: 3, weight: 0.0)
        ]
        let result = TreemapLayout.layout(items: items, in: bounds)
        XCTAssertEqual(result.count, 3)
        for tile in result {
            XCTAssertEqual(tile.rect.width * tile.rect.height, 0)
        }
    }

    // MARK: - Fixtures

    private func uniformItems(count: Int) -> [(id: Int, weight: Double)] {
        (0..<count).map { (id: $0, weight: 100.0) }
    }

    private func mixedItems() -> [(id: Int, weight: Double)] {
        [
            (id: 1, weight: 600),
            (id: 2, weight: 300),
            (id: 3, weight: 150),
            (id: 4, weight: 100),
            (id: 5, weight: 80),
            (id: 6, weight: 40),
            (id: 7, weight: 20),
            (id: 8, weight: 10)
        ]
    }
}
