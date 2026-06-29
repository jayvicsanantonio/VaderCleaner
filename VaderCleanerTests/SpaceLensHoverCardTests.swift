// SpaceLensHoverCardTests.swift
// Locks the hover card's anchor math (placed beside the hovered bubble, never over the cursor, clamped on-canvas) and its modified-date formatting.

import XCTest
import CoreGraphics
@testable import VaderCleaner

/// Unit tests for `SpaceLensHoverCard`'s positioning and formatting helpers.
/// These are pure static functions, so the tests reconstruct the card's
/// rectangle from its returned center and assert it clears the hovered bubble.
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

    // MARK: - Bubble anchoring

    /// A bubble with room beneath it gets a card placed entirely below it, so the
    /// card never overlaps the bubble the pointer is inside.
    func test_anchor_placesCardBelowWhenRoomBelow() {
        let bounds = CGSize(width: 400, height: 300)
        let bubble = CGRect(x: 150, y: 120, width: 100, height: 60)

        let center = SpaceLensHoverCard.anchor(forTile: bubble, in: bounds)
        let card = cardRect(at: center)

        XCTAssertFalse(card.intersects(bubble), "Card overlaps the bubble it describes")
        XCTAssertGreaterThanOrEqual(card.minY, bubble.maxY, "Card should sit below the bubble")
    }

    /// A bubble hugging the bottom edge — no room below — flips the card above it.
    func test_anchor_flipsAboveWhenNoRoomBelow() {
        let bounds = CGSize(width: 400, height: 300)
        let bubble = CGRect(x: 150, y: 240, width: 100, height: 50)

        let center = SpaceLensHoverCard.anchor(forTile: bubble, in: bounds)
        let card = cardRect(at: center)

        XCTAssertFalse(card.intersects(bubble), "Card overlaps the bubble it describes")
        XCTAssertLessThanOrEqual(card.maxY, bubble.minY, "Card should sit above the bubble")
    }

    /// The card stays fully on-canvas regardless of where the bubble sits.
    func test_anchor_keepsCardOnCanvas() {
        let bounds = CGSize(width: 400, height: 300)
        let bubble = CGRect(x: 0, y: 0, width: 60, height: 40)

        let center = SpaceLensHoverCard.anchor(forTile: bubble, in: bounds)

        XCTAssertGreaterThanOrEqual(center.x, halfWidth)
        XCTAssertLessThanOrEqual(center.x, bounds.width - halfWidth)
        XCTAssertGreaterThanOrEqual(center.y, halfHeight)
        XCTAssertLessThanOrEqual(center.y, bounds.height - halfHeight)
    }

    // MARK: - Formatting

    func test_formattedModified_nilWhenNoDate() {
        XCTAssertNil(SpaceLensHoverCard.formattedModified(nil))
    }

    func test_formattedModified_nonEmptyForDate() {
        let formatted = SpaceLensHoverCard.formattedModified(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(formatted)
        XCTAssertFalse(formatted!.isEmpty)
    }
}
