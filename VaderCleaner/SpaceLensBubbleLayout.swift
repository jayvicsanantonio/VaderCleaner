// SpaceLensBubbleLayout.swift
// Deterministic circle-packing for the Space Lens bubble chart — packs weighted siblings tangentially (a Swift port of d3's front-chain packSiblings + Welzl enclose), then scales the cluster to fit a canvas with each bubble's area proportional to its byte size.

import CoreGraphics
import Foundation

/// One packed bubble: the laid-out center and radius for an item, in canvas
/// coordinates. `id` ties the circle back to the `DiskNode` it represents.
struct PackedCircle<ID: Hashable>: Equatable {
    let id: ID
    let center: CGPoint
    let radius: CGFloat
}

/// Pure circle-packing used by `SpaceLensBubbleView`. Holds no SwiftUI and no
/// disk state — it takes weighted items and a target rect and returns
/// non-overlapping circles whose **areas are proportional to their weights**,
/// clustered tightly and centered in the rect.
///
/// The packing is a direct port of d3-hierarchy's `packSiblings` (the
/// Wang et al. front-chain algorithm) plus Welzl's smallest-enclosing-circle
/// (`packEnclose`). d3's randomized shuffle is omitted so the layout is fully
/// deterministic: the same input always yields the same arrangement, which the
/// view relies on so bubbles don't jump between renders.
enum SpaceLensBubbleLayout {

    /// Fraction of the rect's inscribed circle the packed cluster fills. Close
    /// to 1 so the bubbles read large; the view's canvas inset still leaves room
    /// for the edge bubbles' rings and glows.
    private static let fillFraction: CGFloat = 1.0

    /// Gap between neighbouring bubbles, as a fraction of the mean bubble
    /// radius. The pack runs on radii inflated by this much and the bubbles are
    /// drawn at their true size, leaving a consistent breathing space between
    /// them — matching the loosely-spaced clusters in the reference design.
    private static let paddingFraction: CGFloat = 0.22

    /// Floor on a bubble's radius, as a fraction of the largest bubble's radius,
    /// so a tiny (or zero-byte) item still renders a comfortably legible,
    /// tappable bubble rather than collapsing to a dot when one sibling
    /// dominates the folder (e.g. a multi-hundred-GB home folder beside a few-MB
    /// neighbour). Area stays proportional above the floor.
    private static let minRadiusFraction: CGFloat = 0.30

    /// Pack `items` into `bounds`. Every item gets a circle — areas track weight,
    /// but a minimum radius keeps tiny and zero-byte items visible. Returns
    /// circles in input order. Empty input, an all-zero set, or a degenerate
    /// rect yields no circles.
    static func pack<ID: Hashable>(
        items: [(id: ID, weight: Double)],
        in bounds: CGRect
    ) -> [PackedCircle<ID>] {
        guard !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        // True radius ∝ sqrt(weight) so a circle's *area* tracks its weight,
        // floored so the smallest items stay visible.
        let trueRadii = items.map { CGFloat(max(0, $0.weight).squareRoot()) }
        guard let maxRadius = trueRadii.max(), maxRadius > 0 else { return [] }
        let minRadius = maxRadius * minRadiusFraction
        let rawRadii = trueRadii.map { max($0, minRadius) }

        let meanRadius = rawRadii.reduce(0, +) / CGFloat(rawRadii.count)
        let pad = meanRadius * paddingFraction

        // Lay out on padded radii so neighbours end up `2·pad` apart, then draw
        // each bubble at its true radius inside that slot.
        let nodes = rawRadii.map { Node(radius: $0 + pad) }
        let enclosingRadius = packSiblings(nodes)
        guard enclosingRadius > 0 else { return [] }

        // Scale the origin-centered (padded) cluster to fit the rect's inscribed
        // circle, then translate to the rect's center.
        let scale = (min(bounds.width, bounds.height) / 2) * fillFraction / enclosingRadius
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        return zip(zip(items, nodes), rawRadii).map { pair, rawRadius in
            let (item, node) = pair
            return PackedCircle(
                id: item.id,
                center: CGPoint(x: center.x + node.x * scale, y: center.y + node.y * scale),
                radius: rawRadius * scale
            )
        }
    }

    // MARK: - Front-chain packing (d3 packSiblings)

    /// Mutable working circle for the pack. Doubly linked into the front chain
    /// during packing; `x`/`y` are filled in as each circle is placed.
    private final class Node {
        var x: CGFloat = 0
        var y: CGFloat = 0
        let r: CGFloat
        var next: Node?
        var previous: Node?
        init(radius: CGFloat) { self.r = radius }
    }

    /// Places every node tangentially and returns the radius of the enclosing
    /// circle, with all nodes translated so that enclosing circle is centered
    /// on the origin. Mirrors d3's `packSiblingsRandom` step for step.
    private static func packSiblings(_ circles: [Node]) -> CGFloat {
        let n = circles.count
        guard n > 0 else { return 0 }

        var a = circles[0]
        a.x = 0; a.y = 0
        guard n > 1 else { return a.r }

        var b = circles[1]
        a.x = -b.r; b.x = a.r; b.y = 0
        guard n > 2 else { return a.r + b.r }

        var c = circles[2]
        place(b, a, c)

        // Front chain seeded with the first three circles in order a → b → c.
        a.next = b; c.previous = b
        b.next = c; a.previous = c
        c.next = a; b.previous = a

        var i = 3
        pack: while i < n {
            c = circles[i]
            place(a, b, c)

            // Walk outward from b (forward) and a (backward) along the chain,
            // whichever side is "closer", looking for a circle the new one
            // would overlap. On a hit, close the chain over the offender and
            // retry placing the same circle.
            var j = b.next!
            var k = a.previous!
            var sj = b.r
            var sk = a.r
            repeat {
                if sj <= sk {
                    if intersects(j, c) {
                        b = j; a.next = b; b.previous = a
                        continue pack
                    }
                    sj += j.r; j = j.next!
                } else {
                    if intersects(k, c) {
                        a = k; a.next = b; b.previous = a
                        continue pack
                    }
                    sk += k.r; k = k.previous!
                }
            } while j !== k.next

            // No overlap — splice c into the chain between a and b.
            c.previous = a; c.next = b; a.next = c; b.previous = c
            b = c

            // Re-pick the pair nearest the centroid to seed the next placement.
            var aa = score(a)
            var node = c.next!
            while node !== b {
                let ca = score(node)
                if ca < aa { a = node; aa = ca }
                node = node.next!
            }
            b = a.next!
            i += 1
        }

        // Enclosing circle over the whole chain, then recenter on the origin.
        var chain: [Node] = [b]
        var walker = b.next!
        while walker !== b { chain.append(walker); walker = walker.next! }
        let enclosing = enclose(chain)
        for circle in circles { circle.x -= enclosing.x; circle.y -= enclosing.y }
        return enclosing.r
    }

    /// Positions `c` tangent to both `a` and `b` (d3 `place`). Degenerate when
    /// a and b coincide: drop `c` to the right of `a`.
    private static func place(_ b: Node, _ a: Node, _ c: Node) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let d2 = dx * dx + dy * dy
        if d2 > 0 {
            let a2 = (a.r + c.r) * (a.r + c.r)
            let b2 = (b.r + c.r) * (b.r + c.r)
            if a2 > b2 {
                let x = (d2 + b2 - a2) / (2 * d2)
                let y = (max(0, b2 / d2 - x * x)).squareRoot()
                c.x = b.x - x * dx - y * dy
                c.y = b.y - x * dy + y * dx
            } else {
                let x = (d2 + a2 - b2) / (2 * d2)
                let y = (max(0, a2 / d2 - x * x)).squareRoot()
                c.x = a.x + x * dx - y * dy
                c.y = a.y + x * dy + y * dx
            }
        } else {
            c.x = a.x + c.r
            c.y = a.y
        }
    }

    /// Two circles overlap if their separation is less than the sum of radii,
    /// minus a tiny epsilon so tangency doesn't read as intersection.
    private static func intersects(_ a: Node, _ b: Node) -> Bool {
        let dr = a.r + b.r - 1e-6
        let dx = b.x - a.x
        let dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    /// Squared distance of the weighted midpoint of `node` and its successor
    /// from the origin — d3's chain-tightness heuristic for choosing the next
    /// placement pair.
    private static func score(_ node: Node) -> CGFloat {
        let a = node, b = node.next!
        let ab = a.r + b.r
        let dx = (a.x * b.r + b.x * a.r) / ab
        let dy = (a.y * b.r + b.y * a.r) / ab
        return dx * dx + dy * dy
    }

    // MARK: - Smallest enclosing circle (Welzl / d3 packEnclose)

    /// A plain circle value used by the enclosing-circle math.
    private struct Circle { let x: CGFloat; let y: CGFloat; let r: CGFloat }

    /// Smallest circle enclosing every node. Deterministic Welzl (no shuffle):
    /// processes the circles in order, rebuilding the support basis whenever a
    /// circle falls outside the current candidate.
    private static func enclose(_ nodes: [Node]) -> Circle {
        let circles = nodes.map { Circle(x: $0.x, y: $0.y, r: $0.r) }
        var basis: [Circle] = []
        var enclosing: Circle?
        var i = 0
        while i < circles.count {
            let p = circles[i]
            if let e = enclosing, enclosesWeak(e, p) {
                i += 1
            } else {
                basis = extendBasis(basis, p)
                enclosing = encloseBasis(basis)
                i = 0
            }
        }
        return enclosing ?? Circle(x: 0, y: 0, r: 0)
    }

    private static func extendBasis(_ B: [Circle], _ p: Circle) -> [Circle] {
        if enclosesWeakAll(p, B) { return [p] }

        for i in 0..<B.count {
            if enclosesNot(p, B[i]),
               enclosesWeakAll(encloseBasis2(B[i], p), B) {
                return [B[i], p]
            }
        }

        for i in 0..<max(0, B.count - 1) {
            for j in (i + 1)..<B.count {
                if enclosesNot(encloseBasis2(B[i], B[j]), p),
                   enclosesNot(encloseBasis2(B[i], p), B[j]),
                   enclosesNot(encloseBasis2(B[j], p), B[i]),
                   enclosesWeakAll(encloseBasis3(B[i], B[j], p), B) {
                    return [B[i], B[j], p]
                }
            }
        }

        // Unreachable for well-formed input; fall back to the single circle.
        return [p]
    }

    private static func enclosesNot(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r - b.r
        let dx = b.x - a.x
        let dy = b.y - a.y
        return dr < 0 || dr * dr < dx * dx + dy * dy
    }

    private static func enclosesWeak(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r - b.r + max(a.r, b.r, 1) * 1e-9
        let dx = b.x - a.x
        let dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    private static func enclosesWeakAll(_ a: Circle, _ B: [Circle]) -> Bool {
        B.allSatisfy { enclosesWeak(a, $0) }
    }

    private static func encloseBasis(_ B: [Circle]) -> Circle {
        switch B.count {
        case 1:  return B[0]
        case 2:  return encloseBasis2(B[0], B[1])
        default: return encloseBasis3(B[0], B[1], B[2])
        }
    }

    private static func encloseBasis2(_ a: Circle, _ b: Circle) -> Circle {
        let x21 = b.x - a.x, y21 = b.y - a.y, r21 = b.r - a.r
        let l = (x21 * x21 + y21 * y21).squareRoot()
        return Circle(
            x: (a.x + b.x + x21 / l * r21) / 2,
            y: (a.y + b.y + y21 / l * r21) / 2,
            r: (l + a.r + b.r) / 2
        )
    }

    private static func encloseBasis3(_ a: Circle, _ b: Circle, _ c: Circle) -> Circle {
        let x1 = a.x, y1 = a.y, r1 = a.r
        let x2 = b.x, y2 = b.y, r2 = b.r
        let x3 = c.x, y3 = c.y, r3 = c.r
        let a2 = x1 - x2, a3 = x1 - x3
        let b2 = y1 - y2, b3 = y1 - y3
        let c2 = r2 - r1, c3 = r3 - r1
        let d1 = x1 * x1 + y1 * y1 - r1 * r1
        let d2 = d1 - x2 * x2 - y2 * y2 + r2 * r2
        let d3 = d1 - x3 * x3 - y3 * y3 + r3 * r3
        let ab = a3 * b2 - a2 * b3
        let xa = (b2 * d3 - b3 * d2) / (ab * 2) - x1
        let xb = (b3 * c2 - b2 * c3) / ab
        let ya = (a3 * d2 - a2 * d3) / (ab * 2) - y1
        let yb = (a2 * c3 - a3 * c2) / ab
        let A = xb * xb + yb * yb - 1
        let B = 2 * (r1 + xa * xb + ya * yb)
        let C = xa * xa + ya * ya - r1 * r1
        let r = -(abs(A) > 1e-6 ? (B + (B * B - 4 * A * C).squareRoot()) / (2 * A) : C / B)
        return Circle(x: x1 + xa + xb * r, y: y1 + ya + yb * r, r: r)
    }
}
