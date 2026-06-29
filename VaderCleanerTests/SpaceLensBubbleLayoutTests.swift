// SpaceLensBubbleLayoutTests.swift
// Verifies the Space Lens circle-packing: determinism, non-overlap, area-proportional radii, and that the packed cluster stays within the canvas.

import XCTest
import CoreGraphics
@testable import VaderCleaner

final class SpaceLensBubbleLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - Degenerate input

    func test_pack_emptyInput_returnsNoCircles() {
        let circles = SpaceLensBubbleLayout.pack(items: [] as [(id: Int, weight: Double)], in: bounds)
        XCTAssertTrue(circles.isEmpty)
    }

    func test_pack_allZeroWeight_returnsNoCircles() {
        let circles = SpaceLensBubbleLayout.pack(
            items: [(id: 1, weight: 0.0), (id: 2, weight: 0.0)],
            in: bounds
        )
        XCTAssertTrue(circles.isEmpty)
    }

    func test_pack_zeroWeightItemStillGetsAMinimumBubble() {
        let circles = SpaceLensBubbleLayout.pack(
            items: [(id: 1, weight: 10_000.0), (id: 2, weight: 0.0)],
            in: bounds
        )
        XCTAssertEqual(circles.count, 2)
        let big = circles.first { $0.id == 1 }!
        let tiny = circles.first { $0.id == 2 }!
        XCTAssertGreaterThan(tiny.radius, 0, "zero-byte item should still render a bubble")
        XCTAssertLessThan(tiny.radius, big.radius, "the zero-byte bubble must be the minimum size")
    }

    func test_pack_singleItem_isCenteredInBounds() {
        let circles = SpaceLensBubbleLayout.pack(items: [(id: 1, weight: 100.0)], in: bounds)
        let only = try? XCTUnwrap(circles.first)
        XCTAssertEqual(circles.count, 1)
        XCTAssertEqual(only?.center.x ?? 0, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(only?.center.y ?? 0, bounds.midY, accuracy: 0.001)
        XCTAssertGreaterThan(only?.radius ?? 0, 0)
    }

    // MARK: - Core invariants

    func test_pack_areaIsProportionalToWeight() {
        // weight 400 vs 100 → radius ratio sqrt(4) = 2.
        let circles = SpaceLensBubbleLayout.pack(
            items: [(id: "big", weight: 400.0), (id: "small", weight: 100.0)],
            in: bounds
        )
        let big = circles.first { $0.id == "big" }!
        let small = circles.first { $0.id == "small" }!
        XCTAssertEqual(big.radius / small.radius, 2.0, accuracy: 0.01)
    }

    func test_pack_circlesDoNotOverlap() {
        let items = (0..<25).map { (id: $0, weight: Double(($0 % 7 + 1) * 50)) }
        let circles = SpaceLensBubbleLayout.pack(items: items, in: bounds)
        XCTAssertEqual(circles.count, items.count)

        for i in 0..<circles.count {
            for j in (i + 1)..<circles.count {
                let a = circles[i], b = circles[j]
                let dx = b.center.x - a.center.x
                let dy = b.center.y - a.center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                // Allow a sub-pixel tolerance for tangency / float error.
                XCTAssertGreaterThanOrEqual(
                    distance, a.radius + b.radius - 0.5,
                    "circles \(a.id) and \(b.id) overlap"
                )
            }
        }
    }

    func test_pack_circlesStayWithinBounds() {
        let items = (0..<20).map { (id: $0, weight: Double(($0 % 5 + 1) * 80)) }
        let circles = SpaceLensBubbleLayout.pack(items: items, in: bounds)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let inscribed = min(bounds.width, bounds.height) / 2

        for c in circles {
            let dx = c.center.x - center.x
            let dy = c.center.y - center.y
            let reach = (dx * dx + dy * dy).squareRoot() + c.radius
            XCTAssertLessThanOrEqual(reach, inscribed + 0.5, "circle \(c.id) escapes the canvas")
        }
    }

    func test_pack_isDeterministic() {
        let items = (0..<30).map { (id: $0, weight: Double(($0 * 37 % 11 + 1) * 25)) }
        let first = SpaceLensBubbleLayout.pack(items: items, in: bounds)
        let second = SpaceLensBubbleLayout.pack(items: items, in: bounds)
        XCTAssertEqual(first, second)
    }
}
