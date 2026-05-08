// TreemapLayout.swift
// Squarified treemap layout (Bruls/Huijse/van Wijk) — turns a list of weighted items into rectangles inside a bounding box, keeping every tile as close to square as possible.

import CoreGraphics

/// Pure value type. Given a set of weighted items and a bounding rectangle,
/// produces a list of `(id, CGRect)` whose rectangles partition the bounds
/// in proportion to the input weights.
///
/// Implements the squarified algorithm from Bruls, Huijse & van Wijk (2000).
/// The naive "slice and dice" alternative is one line shorter to write but
/// degrades to long stripes whose worst aspect ratio scales linearly with
/// the input size, defeating the at-a-glance comparison the treemap exists
/// to enable. The unit-test suite exercises the squarified-quality property
/// directly with a worst-aspect-ratio gate.
///
/// **Generic over `ID`** rather than tied to `DiskNode` so unit tests can
/// drive it with `Int` ids (no `URL`s, no fixture trees) and so future
/// callers — Smart Scan summary, Large Files breakdown — can use it
/// without dragging in the disk-scanner types.
///
/// **No state** — every call is independent. The layout result keys back
/// to the input ids so the SwiftUI view can pair tiles with their source
/// nodes through a dictionary lookup.
struct TreemapLayout {

    /// Layout entry point. The result is the same length as `items` (every
    /// id appears exactly once). Tile order in the result is implementation-
    /// defined: the algorithm sorts internally so the largest tiles land in
    /// the upper-left strip first. Callers should look up tiles by id, not
    /// by position.
    ///
    /// **Edge cases:**
    /// - Empty input → empty output.
    /// - All-zero weights → every tile reports a zero-area rect at the
    ///   bounds origin. The SwiftUI view can still iterate the result;
    ///   tiles below ~4 pt in either dimension are skipped at render time.
    /// - Negative or NaN weights → clamped to 0. (Treemap weights model
    ///   on-disk byte counts; negatives are nonsensical and silently
    ///   discarded rather than trapped — a single corrupt scan record
    ///   should not crash the visualization.)
    static func layout<ID: Hashable>(
        items: [(id: ID, weight: Double)],
        in bounds: CGRect
    ) -> [(id: ID, rect: CGRect)] {
        guard !items.isEmpty else { return [] }
        guard bounds.width > 0, bounds.height > 0 else {
            return items.map { (id: $0.id, rect: CGRect(origin: bounds.origin, size: .zero)) }
        }

        // Clamp negatives / NaN to 0 so a single corrupt input doesn't poison
        // the totals. `isFinite` guards against an `Double.infinity` leaking
        // in from a divide-by-zero upstream.
        let cleaned: [(id: ID, weight: Double)] = items.map { item in
            let w = item.weight
            return (id: item.id, weight: (w.isFinite && w > 0) ? w : 0)
        }

        let totalWeight = cleaned.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return cleaned.map { (id: $0.id, rect: CGRect(origin: bounds.origin, size: .zero)) }
        }

        // Convert weights to areas in the bounds' coordinate space. Doing
        // this once up front lets the recursion compare areas directly to
        // the remaining-rect dimensions without re-deriving the scale.
        let scale = Double(bounds.width) * Double(bounds.height) / totalWeight
        let scaled: [Item<ID>] = cleaned
            .map { Item(id: $0.id, area: $0.weight * scale) }
            .sorted { $0.area > $1.area }

        var output: [(id: ID, rect: CGRect)] = []
        output.reserveCapacity(items.count)
        squarify(items: scaled, in: bounds, output: &output)
        return output
    }

    // MARK: - Internals

    /// Internal pair carried through the recursion. Kept distinct from the
    /// public input tuple so the algorithm always reasons about pre-scaled
    /// areas, never raw weights.
    private struct Item<ID: Hashable> {
        let id: ID
        let area: Double
    }

    /// Recursive driver. Maintains a "row" of items being placed along the
    /// shorter side of `remaining`. As long as adding the next item to the
    /// row improves (or ties) the worst aspect ratio, it joins the row;
    /// otherwise the row is flushed as a strip and recursion continues
    /// with the leftover rectangle.
    private static func squarify<ID: Hashable>(
        items: [Item<ID>],
        in bounds: CGRect,
        output: inout [(id: ID, rect: CGRect)]
    ) {
        var remaining = bounds
        var row: [Item<ID>] = []
        var index = 0

        while index < items.count {
            let next = items[index]
            let shortSide = min(Double(remaining.width), Double(remaining.height))

            // Trying the item with the row vs. without. When the row is
            // empty, "without" is undefined (no aspect ratio yet) and we
            // always accept the first item. Otherwise we accept whichever
            // gives the smaller worst ratio.
            let proposed = row + [next]
            let worstWith = worstRatio(row: proposed, shortSide: shortSide)
            let worstWithout = row.isEmpty
                ? Double.infinity
                : worstRatio(row: row, shortSide: shortSide)

            if row.isEmpty || worstWith <= worstWithout {
                row = proposed
                index += 1
            } else {
                // Adding this item makes the row worse — flush the current
                // row first, then re-try the same item against the new
                // remaining rectangle.
                let leftover = layoutRow(row, in: remaining, output: &output)
                remaining = leftover
                row = []
                if remaining.width <= 0 || remaining.height <= 0 {
                    // Numerical exhaustion — emit zero-area placeholders for
                    // anything still queued so the output array length
                    // matches `items.count` (the public contract).
                    for tail in items[index...] {
                        output.append((id: tail.id, rect: CGRect(origin: bounds.origin, size: .zero)))
                    }
                    return
                }
            }
        }

        if !row.isEmpty {
            _ = layoutRow(row, in: remaining, output: &output)
        }
    }

    /// Worst aspect ratio achievable when `row` is laid as a strip along
    /// `shortSide`. The Bruls et al. closed form: for a strip with total
    /// area `s` and `n` items, the worst ratio is the max over items of
    /// `max(w² · max_a / s², s² / (w² · min_a))` where `w` = shortSide.
    /// Returns `.infinity` for degenerate inputs (empty row, zero area,
    /// zero short side) so the caller treats them as unacceptable and
    /// either flushes or accepts the first item by the empty-row rule.
    private static func worstRatio<ID: Hashable>(
        row: [Item<ID>],
        shortSide: Double
    ) -> Double {
        guard !row.isEmpty, shortSide > 0 else { return .infinity }
        let totalArea = row.reduce(0.0) { $0 + $1.area }
        guard totalArea > 0 else { return .infinity }

        let s2 = shortSide * shortSide
        let totalArea2 = totalArea * totalArea
        var worst = 0.0
        for item in row {
            guard item.area > 0 else { continue }
            let aspectA = (s2 * item.area) / totalArea2
            let aspectB = totalArea2 / (s2 * item.area)
            worst = max(worst, max(aspectA, aspectB))
        }
        // If every item in the row had zero area, no ratio could be
        // computed — return `.infinity` so the caller flushes the row
        // rather than committing zero-byte items to a strip that won't
        // render anyway.
        return worst > 0 ? worst : .infinity
    }

    /// Place the strip and return the rectangle left over for subsequent
    /// rows. The strip occupies a slab of thickness `totalArea / shortSide`
    /// against the shorter side of `rect`; items inside the strip are laid
    /// end-to-end along the longer of the strip's two dimensions.
    ///
    /// Returns the unconsumed rectangle. Falls back to the input rect when
    /// the strip is degenerate (zero area or zero short side) so the
    /// caller's loop can detect the no-progress case via the
    /// `remaining.width <= 0` / `<= 0` guard.
    private static func layoutRow<ID: Hashable>(
        _ row: [Item<ID>],
        in rect: CGRect,
        output: inout [(id: ID, rect: CGRect)]
    ) -> CGRect {
        let totalArea = row.reduce(0.0) { $0 + $1.area }
        let shortSide = min(Double(rect.width), Double(rect.height))
        guard shortSide > 0, totalArea > 0 else {
            for item in row {
                output.append((id: item.id, rect: CGRect(origin: rect.origin, size: .zero)))
            }
            return rect
        }

        let stripThickness = totalArea / shortSide

        if rect.width >= rect.height {
            // Vertical strip on the left edge: each item takes the full
            // strip width and a slice of its height.
            var y = Double(rect.minY)
            for item in row {
                let height = item.area / stripThickness
                let tile = CGRect(
                    x: Double(rect.minX),
                    y: y,
                    width: stripThickness,
                    height: height
                )
                output.append((id: item.id, rect: tile))
                y += height
            }
            return CGRect(
                x: Double(rect.minX) + stripThickness,
                y: Double(rect.minY),
                width: Double(rect.width) - stripThickness,
                height: Double(rect.height)
            )
        } else {
            // Horizontal strip on the top edge.
            var x = Double(rect.minX)
            for item in row {
                let width = item.area / stripThickness
                let tile = CGRect(
                    x: x,
                    y: Double(rect.minY),
                    width: width,
                    height: stripThickness
                )
                output.append((id: item.id, rect: tile))
                x += width
            }
            return CGRect(
                x: Double(rect.minX),
                y: Double(rect.minY) + stripThickness,
                width: Double(rect.width),
                height: Double(rect.height) - stripThickness
            )
        }
    }
}
