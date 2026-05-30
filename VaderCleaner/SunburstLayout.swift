// SunburstLayout.swift
// Pure radial-sunburst layout — turns a weighted node hierarchy into flat annular-sector segments (id, depth, start/end angle), dividing each ring's angular span in proportion to size.

import Foundation
import CoreGraphics

/// Pure value type. Given a node hierarchy, produces a flat list of
/// `(id, depth, startAngle, endAngle)` segments describing a radial sunburst:
/// the root is the hollow center, its children fill the first ring, their
/// children the second, and so on out to `maxDepth`.
///
/// **Angles-only.** A sunburst segment is an annular sector, but the *angles*
/// depend solely on size ratios — `childArc = child.weight / Σ(siblings) ×
/// parentArc`, anchored at the parent's start and accumulated clockwise. None
/// of that touches pixels. The mapping from `depth` to inner/outer radius is a
/// render-time concern of `SunburstView`, so this layout emits no geometry.
/// That keeps it trivially testable (assert angles, no coordinate math) and
/// means a window resize only rescales radii, never re-walks the tree.
///
/// **Generic over the node type** via closures (`id` / `weight` / `children`)
/// rather than tied to `DiskNode`, mirroring `TreemapLayout`: unit tests drive
/// it with lightweight `Int`-keyed fixtures and future callers can reuse it
/// without importing the disk-scanner types.
///
/// **No state** — every call is independent. Segments key back to the input
/// ids so the view can pair each arc with its source node via a dictionary
/// lookup.
struct SunburstLayout {

    /// One placed arc. `depth` is 1 for the root's immediate children, 2 for
    /// grandchildren, and so on; the root itself is never emitted (it is the
    /// center hole). Angles are in radians, strictly increasing from the
    /// layout's `startAngle`.
    struct Segment<ID: Hashable>: Equatable, Identifiable {
        let id: ID
        let depth: Int
        let startAngle: Double
        let endAngle: Double
    }

    /// Smallest arc, in radians, still worth emitting (~1.5°). A child thinner
    /// than this — and its whole subtree — is pruned: the wedge would be too
    /// narrow to see or click, and recursing into it only multiplies the
    /// noise. Mirrors the treemap's `minRenderDimension` sliver skip.
    static let minSegmentAngle: Double = 1.5 * .pi / 180

    /// Layout entry point.
    ///
    /// - Parameters:
    ///   - root: the node whose subtree fills the rings. Its own arc is not
    ///     emitted; its children populate depth 1.
    ///   - maxDepth: deepest ring to emit. Nodes below this are dropped so the
    ///     outer rings stay legible (the reference UI's ~7 rings get too thin).
    ///   - startAngle: angle (radians) where the first ring begins. Defaults to
    ///     `-π/2` so the sweep starts at 12 o'clock.
    ///   - sweep: total angular span to fill (radians). Defaults to a full
    ///     circle; carved-out partial sunbursts can pass less.
    ///   - id / weight / children: accessors into the caller's node type.
    ///
    /// **Edge cases:** empty children → empty output; negative / NaN /
    /// non-finite / zero weights clamp to 0 and emit nothing; a parent whose
    /// surviving siblings all clamp to 0 contributes no segments.
    static func segments<Node, ID: Hashable>(
        root: Node,
        maxDepth: Int,
        startAngle: Double = -.pi / 2,
        sweep: Double = 2 * .pi,
        id: (Node) -> ID,
        weight: (Node) -> Double,
        children: (Node) -> [Node]
    ) -> [Segment<ID>] {
        guard maxDepth >= 1, sweep > 0 else { return [] }
        var output: [Segment<ID>] = []
        place(
            parentChildren: children(root),
            depth: 1,
            spanStart: startAngle,
            spanWidth: sweep,
            maxDepth: maxDepth,
            id: id,
            weight: weight,
            children: children,
            output: &output
        )
        return output
    }

    /// Inverse of the layout: given a point in the view's coordinate space,
    /// return the id of the segment drawn under it (or `nil` for the center
    /// hole, the gaps left by pruned slivers, or anywhere past the outer ring).
    ///
    /// This is what the hover and tap code uses so the reported item matches
    /// the pointer exactly, instead of relying on overlapping `Shape` hit
    /// regions. It must agree with how `SunburstView` maps `depth` to radius:
    /// `innerR = innerHole + (depth-1)·ringThickness`, `outerR = innerHole +
    /// depth·ringThickness`. The angle convention matches the renderer too —
    /// `atan2` in SwiftUI's y-down space increases clockwise from 3 o'clock, so
    /// with the default `startAngle` of `-π/2` the sweep starts at 12 o'clock,
    /// exactly as `addArc(clockwise: false)` draws it.
    static func segment<ID: Hashable>(
        at point: CGPoint,
        center: CGPoint,
        innerHole: CGFloat,
        ringThickness: CGFloat,
        startAngle: Double = -.pi / 2,
        segments: [Segment<ID>]
    ) -> ID? {
        guard ringThickness > 0 else { return nil }

        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= Double(innerHole) else { return nil }

        // Normalize the pointer angle into `[startAngle, startAngle + 2π)` so it
        // can be compared against the segments' (also-increasing) angle ranges.
        let twoPi = 2 * Double.pi
        var angle = atan2(dy, dx)
        while angle < startAngle { angle += twoPi }
        while angle >= startAngle + twoPi { angle -= twoPi }

        let hole = Double(innerHole)
        let thickness = Double(ringThickness)
        for segment in segments {
            let inner = hole + Double(segment.depth - 1) * thickness
            let outer = hole + Double(segment.depth) * thickness
            if radius >= inner, radius <= outer,
               angle >= segment.startAngle, angle < segment.endAngle {
                return segment.id
            }
        }
        return nil
    }

    // MARK: - Internals

    /// Place one ring's worth of children inside `[spanStart, spanStart +
    /// spanWidth]`, then recurse into each surviving child's own sub-arc.
    ///
    /// Proportions are taken against the *cleaned* sibling total so the
    /// children exactly tile the parent's span (no rounding gap). A child whose
    /// resulting arc is below `minSegmentAngle` is skipped — both its segment
    /// and its subtree — which leaves a small gap where the sliver would have
    /// been rather than redistributing, keeping every surviving sibling at its
    /// true proportional position.
    private static func place<Node, ID: Hashable>(
        parentChildren: [Node],
        depth: Int,
        spanStart: Double,
        spanWidth: Double,
        maxDepth: Int,
        id: (Node) -> ID,
        weight: (Node) -> Double,
        children: (Node) -> [Node],
        output: inout [Segment<ID>]
    ) {
        guard depth <= maxDepth else { return }

        // Clamp non-finite / negative weights to 0, then order largest-first so
        // the dominant folders lead the ring clockwise (matches the treemap's
        // largest-first emphasis and the reference visualization).
        let cleaned = parentChildren
            .map { (node: $0, weight: cleanWeight(weight($0))) }
            .filter { $0.weight > 0 }
            .sorted { $0.weight > $1.weight }

        let total = cleaned.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return }

        // Sliver pruning exists to drop a tiny child next to larger siblings —
        // not to blank out a whole ring. When *no* child clears the threshold
        // (a folder with hundreds of similarly-sized items), pruning them all
        // would render an empty ring for a non-empty folder. In that case keep
        // every child so the ring fills; they're drawn as leaves because
        // recursing into a sliver only repeats the situation one ring out.
        let anyClears = cleaned.contains { ($0.weight / total) * spanWidth >= minSegmentAngle }

        var cursor = spanStart
        for entry in cleaned {
            let arc = entry.weight / total * spanWidth
            let segStart = cursor
            let segEnd = cursor + arc
            cursor = segEnd

            // Prune individual slivers only when a non-sliver sibling exists.
            if anyClears && arc < minSegmentAngle { continue }

            output.append(
                Segment(id: id(entry.node), depth: depth, startAngle: segStart, endAngle: segEnd)
            )
            // Only descend into segments wide enough to carry a readable inner
            // ring; forced-visible slivers (the `!anyClears` case) stay leaves.
            guard arc >= minSegmentAngle else { continue }
            place(
                parentChildren: children(entry.node),
                depth: depth + 1,
                spanStart: segStart,
                spanWidth: arc,
                maxDepth: maxDepth,
                id: id,
                weight: weight,
                children: children,
                output: &output
            )
        }
    }

    /// Treat negative, NaN, and ±infinity weights as zero. Sunburst weights
    /// model on-disk byte counts; a corrupt record should drop out quietly
    /// rather than skew the angles or crash the recursion.
    private static func cleanWeight(_ w: Double) -> Double {
        (w.isFinite && w > 0) ? w : 0
    }
}
