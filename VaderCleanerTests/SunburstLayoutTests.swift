// SunburstLayoutTests.swift
// Locks the radial sunburst layout's invariants: full-circle coverage for a single child, angular proportionality, sibling contiguity, depth nesting and the maxDepth cap, sub-threshold sliver pruning, and the clamped / zero-weight edge cases.

import XCTest
import CoreGraphics
@testable import VaderCleaner

/// Unit tests for `SunburstLayout`. Like `TreemapLayout`, the layout is a pure
/// value type with no dependence on `DiskNode` — it is generic over a node
/// type via closures — so these tests drive it with a lightweight in-memory
/// `Tree` fixture keyed by `Int`. Angles are asserted directly; there is no
/// pixel/coordinate math to verify because the layout is angles-only (radii
/// are a render-time concern of `SunburstView`).
final class SunburstLayoutTests: XCTestCase {

    /// Lightweight fixture tree. Mirrors the shape `SunburstLayout` walks via
    /// closures without dragging in `DiskNode` or `URL`s.
    private struct Tree {
        let id: Int
        let weight: Double
        let children: [Tree]

        init(_ id: Int, _ weight: Double, _ children: [Tree] = []) {
            self.id = id
            self.weight = weight
            self.children = children
        }
    }

    private let start = -Double.pi / 2
    private let sweep = 2 * Double.pi
    private let eps = 1e-9

    private func segments(_ root: Tree, maxDepth: Int = 5) -> [SunburstLayout.Segment<Int>] {
        SunburstLayout.segments(
            root: root,
            maxDepth: maxDepth,
            startAngle: start,
            sweep: sweep,
            id: { $0.id },
            weight: { $0.weight },
            children: { $0.children }
        )
    }

    // MARK: - Coverage & proportionality

    /// A root with no children produces no segments — the view renders just
    /// the empty center hole.
    func test_segments_emptyForNoChildren() {
        let result = segments(Tree(0, 100))
        XCTAssertTrue(result.isEmpty)
    }

    /// A single child must span the entire circle at depth 1. Without this a
    /// folder with one subfolder would render a thin wedge in an otherwise
    /// empty ring.
    func test_segments_singleChildFillsFullSweep() {
        let result = segments(Tree(0, 100, [Tree(1, 100)]))
        XCTAssertEqual(result.count, 1)
        let only = result[0]
        XCTAssertEqual(only.id, 1)
        XCTAssertEqual(only.depth, 1)
        XCTAssertEqual(only.startAngle, start, accuracy: eps)
        XCTAssertEqual(only.endAngle, start + sweep, accuracy: eps)
    }

    /// Sibling arcs are proportional to weight. A 3:1 split yields a
    /// three-quarter arc and a one-quarter arc.
    func test_segments_splitsAngleProportionally() {
        // Largest-first ordering: the weight-75 child leads.
        let result = segments(Tree(0, 100, [Tree(1, 25), Tree(2, 75)]))
        XCTAssertEqual(result.count, 2)

        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let big = try! XCTUnwrap(byID[2])
        let small = try! XCTUnwrap(byID[1])
        XCTAssertEqual(big.endAngle - big.startAngle, sweep * 0.75, accuracy: eps)
        XCTAssertEqual(small.endAngle - small.startAngle, sweep * 0.25, accuracy: eps)
    }

    /// Top-level siblings tile the full circle with no gaps or overlaps:
    /// consecutive arcs meet exactly and the last reaches `start + sweep`.
    func test_segments_topLevelSiblingsAreContiguous() {
        let result = segments(Tree(0, 100, [Tree(1, 50), Tree(2, 30), Tree(3, 20)]))
            .filter { $0.depth == 1 }
            .sorted { $0.startAngle < $1.startAngle }
        XCTAssertEqual(result.count, 3)

        XCTAssertEqual(result.first?.startAngle ?? .nan, start, accuracy: eps)
        XCTAssertEqual(result.last?.endAngle ?? .nan, start + sweep, accuracy: eps)
        for i in 0..<(result.count - 1) {
            XCTAssertEqual(result[i].endAngle, result[i + 1].startAngle, accuracy: eps,
                           "Arc \(i) must end exactly where arc \(i + 1) begins")
        }
    }

    // MARK: - Depth

    /// Children nest inside their parent's angular span at the next depth, and
    /// the grandchild fills the parent's full sub-arc.
    func test_segments_nestsChildrenWithinParentSpan() {
        let result = segments(Tree(0, 100, [
            Tree(1, 50, [Tree(11, 50)]),
            Tree(2, 50)
        ]))
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let parent = try! XCTUnwrap(byID[1])
        let child = try! XCTUnwrap(byID[11])
        XCTAssertEqual(child.depth, 2)
        // Sole child fills the parent's arc exactly.
        XCTAssertEqual(child.startAngle, parent.startAngle, accuracy: eps)
        XCTAssertEqual(child.endAngle, parent.endAngle, accuracy: eps)
    }

    /// `maxDepth` caps the recursion — nodes deeper than the limit are not
    /// emitted, so the outer rings never grow thinner than the view can draw.
    func test_segments_respectsMaxDepth() {
        let deep = Tree(0, 100, [Tree(1, 100, [Tree(2, 100, [Tree(3, 100)])])])
        let result = segments(deep, maxDepth: 2)
        XCTAssertEqual(result.map(\.depth).max(), 2)
        XCTAssertFalse(result.contains { $0.id == 3 }, "Depth-3 node must be pruned at maxDepth 2")
    }

    // MARK: - Pruning & clamping

    /// A child whose arc would be thinner than `minSegmentAngle` is dropped,
    /// along with its descendants — too thin to see or click. The surviving
    /// sibling keeps its own proportional position.
    func test_segments_prunesSliversAndTheirDescendants() {
        // 1000 : 1 → the sliver's arc is ~0.006 rad, far below the threshold.
        let result = segments(Tree(0, 1001, [
            Tree(1, 1000),
            Tree(2, 1, [Tree(21, 1)])
        ]))
        XCTAssertTrue(result.contains { $0.id == 1 }, "The large sibling must survive")
        XCTAssertFalse(result.contains { $0.id == 2 }, "Sub-threshold sliver must be pruned")
        XCTAssertFalse(result.contains { $0.id == 21 }, "A pruned sliver's descendants must be pruned too")
    }

    /// Negative, NaN, and infinite weights clamp to zero and produce no
    /// segment, so a single corrupt scan record can't poison the layout. A
    /// valid sibling still renders.
    func test_segments_clampsNonFiniteAndNegativeWeights() {
        let result = segments(Tree(0, 100, [
            Tree(1, -10),
            Tree(2, .nan),
            Tree(3, .infinity),
            Tree(4, 100)
        ]))
        XCTAssertEqual(result.count, 1)
        let only = try! XCTUnwrap(result.first)
        XCTAssertEqual(only.id, 4)
        XCTAssertEqual(only.endAngle - only.startAngle, sweep, accuracy: eps)
    }

    /// All-zero sibling weights cannot divide by zero; the result is simply
    /// empty (nothing to draw).
    func test_segments_handlesAllZeroWeights() {
        let result = segments(Tree(0, 0, [Tree(1, 0), Tree(2, 0)]))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Hit testing (screen space)

    /// `segment(at:)` must map *pixel* positions to the visually-correct
    /// segment, which is the only thing that proves the `atan2` + y-down +
    /// `-π/2`-at-12-o'clock convention agrees with what the renderer draws.
    ///
    /// Fixture: a 75/25 split. Largest-first, the 75% child (id 2) occupies
    /// `[-π/2, π]` — 12 o'clock clockwise through 3 and 6 o'clock — and the
    /// 25% child (id 1) occupies `[π, 3π/2]`, the top-left quadrant. Center is
    /// (100, 100); the single ring spans radius 0…50.
    func test_segmentAt_mapsCardinalPointsToVisuallyCorrectSegments() {
        let segs = segments(Tree(0, 100, [Tree(1, 25), Tree(2, 75)]))
        let center = CGPoint(x: 100, y: 100)

        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            SunburstLayout.segment(
                at: CGPoint(x: x, y: y),
                center: center,
                innerHole: 0,
                ringThickness: 50,
                segments: segs
            )
        }

        // 12 o'clock, 3 o'clock, 6 o'clock all land in the 75% child (id 2).
        XCTAssertEqual(hit(100, 70), 2, "Straight up should hit the segment that starts at 12 o'clock")
        XCTAssertEqual(hit(130, 100), 2, "Right (3 o'clock) should hit the 75% segment")
        XCTAssertEqual(hit(100, 130), 2, "Down (6 o'clock) should hit the 75% segment")
        // Top-left quadrant lands in the 25% child (id 1).
        XCTAssertEqual(hit(79, 79), 1, "Top-left should hit the 25% segment")
    }

    /// Points inside the center hole and beyond the outer ring resolve to
    /// nothing — the hole shows the total label, and past the rings is empty
    /// canvas.
    func test_segmentAt_returnsNilOutsideTheRings() {
        let segs = segments(Tree(0, 100, [Tree(1, 100)]))
        let center = CGPoint(x: 100, y: 100)

        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            SunburstLayout.segment(
                at: CGPoint(x: x, y: y),
                center: center,
                innerHole: 20,
                ringThickness: 50,
                segments: segs
            )
        }

        XCTAssertNil(hit(100, 105), "A point inside the center hole hits nothing")
        XCTAssertNil(hit(100, 100 - 90), "A point past the outer ring hits nothing")
        XCTAssertEqual(hit(100, 100 - 45), 1, "A point within the ring hits the only segment")
    }
}
