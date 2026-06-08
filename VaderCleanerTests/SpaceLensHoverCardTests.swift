// SpaceLensHoverCardTests.swift
// Locks the hover card's anchor math: the card is placed beside the hovered item (outside a treemap tile, past a sunburst arc) so it never covers the pointer, while staying clamped on-canvas.

import XCTest
import CoreGraphics
@testable import VaderCleaner

/// Unit tests for `SpaceLensHoverCard`'s positioning helpers. These are pure
/// static functions, so the tests reconstruct the card's rectangle from its
/// returned center and assert it clears the hovered item — the property that
/// keeps the tooltip off the cursor.
final class SpaceLensHoverCardTests: XCTestCase {

    private let halfWidth = SpaceLensHoverCard.preferredWidth / 2
    private let halfHeight = SpaceLensHoverCard.halfHeight

    /// The card rectangle implied by a returned center.
    private func cardRect(at center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: SpaceLensHoverCard.preferredWidth,
            height: halfHeight * 2
        )
    }

    // MARK: - Treemap tiles

    /// A tile with room beneath it gets a card placed entirely below it, so the
    /// card never overlaps the tile the pointer is inside.
    func test_tileAnchor_placesCardBelowWhenRoomBelow() {
        let bounds = CGSize(width: 400, height: 300)
        let tile = CGRect(x: 150, y: 120, width: 100, height: 60)

        let center = SpaceLensHoverCard.anchor(forTile: tile, in: bounds)
        let card = cardRect(at: center)

        XCTAssertFalse(card.intersects(tile), "Card overlaps the tile it describes")
        XCTAssertGreaterThanOrEqual(card.minY, tile.maxY, "Card should sit below the tile")
    }

    /// A tile hugging the bottom edge — no room below — flips the card above it.
    func test_tileAnchor_flipsAboveWhenNoRoomBelow() {
        let bounds = CGSize(width: 400, height: 300)
        let tile = CGRect(x: 150, y: 240, width: 100, height: 50)

        let center = SpaceLensHoverCard.anchor(forTile: tile, in: bounds)
        let card = cardRect(at: center)

        XCTAssertFalse(card.intersects(tile), "Card overlaps the tile it describes")
        XCTAssertLessThanOrEqual(card.maxY, tile.minY, "Card should sit above the tile")
    }

    /// The card stays fully on-canvas regardless of where the tile sits.
    func test_tileAnchor_keepsCardOnCanvas() {
        let bounds = CGSize(width: 400, height: 300)
        let tile = CGRect(x: 0, y: 0, width: 60, height: 40)

        let center = SpaceLensHoverCard.anchor(forTile: tile, in: bounds)

        XCTAssertGreaterThanOrEqual(center.x, halfWidth)
        XCTAssertLessThanOrEqual(center.x, bounds.width - halfWidth)
        XCTAssertGreaterThanOrEqual(center.y, halfHeight)
        XCTAssertLessThanOrEqual(center.y, bounds.height - halfHeight)
    }

    // MARK: - Sunburst segments

    /// Closest distance from `point` to the edge of axis-aligned `rect`
    /// (0 when the point is inside).
    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// On a canvas large enough to fit the card beside the ring, the card clears
    /// the segment's arc at every angle — including 3/9 o'clock, where the card's
    /// width (not its height) is the clearance that matters.
    func test_segmentAnchor_clearsArcInAllDirections() {
        let bounds = CGSize(width: 800, height: 800)
        let center = CGPoint(x: 400, y: 400)
        let outerRadius: CGFloat = 140

        let angles: [Double] = [
            0, .pi / 2, .pi, 3 * .pi / 2,        // cardinal
            .pi / 4, 3 * .pi / 4, 5 * .pi / 4    // diagonal
        ]

        for angle in angles {
            let anchor = SpaceLensHoverCard.anchor(
                forSegmentMidAngle: angle,
                outerRadius: outerRadius,
                center: center,
                in: bounds
            )
            let card = cardRect(at: anchor)
            // The arc lives within `outerRadius` of center; the card must not
            // intrude into that disc.
            XCTAssertGreaterThanOrEqual(
                distance(from: center, to: card), outerRadius,
                "Card intrudes on the arc at angle \(angle)"
            )
        }
    }

    /// The card stays fully on-canvas even when the radial push would otherwise
    /// run it off the edge.
    func test_segmentAnchor_keepsCardOnCanvas() {
        let bounds = CGSize(width: 360, height: 360)
        let center = CGPoint(x: 180, y: 180)

        let anchor = SpaceLensHoverCard.anchor(
            forSegmentMidAngle: 0,
            outerRadius: 120,
            center: center,
            in: bounds
        )

        XCTAssertGreaterThanOrEqual(anchor.x, halfWidth)
        XCTAssertLessThanOrEqual(anchor.x, bounds.width - halfWidth)
        XCTAssertGreaterThanOrEqual(anchor.y, halfHeight)
        XCTAssertLessThanOrEqual(anchor.y, bounds.height - halfHeight)
    }
}
