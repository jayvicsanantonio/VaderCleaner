// SpaceLensChildren.swift
// Builds the display rows shared by the Space Lens list and bubble chart — the largest children shown individually, with the long tail folded into a single "Other items" aggregate.

import Foundation

/// One row in the Space Lens list / one bubble in the chart. Either a real
/// child node or the synthetic "Other items" aggregate that folds the long tail
/// of small children into one entry (matching the reference UI).
struct SpaceLensDisplayItem: Identifiable, Equatable {

    /// Stable id: the node's id for a real child, a fixed sentinel for the
    /// aggregate so SwiftUI keeps it stable across renders.
    let id: AnyHashable
    let name: String
    let size: Int64
    let itemCount: Int
    /// The backing node, or `nil` for the "Other items" aggregate.
    let node: DiskNode?
    /// The children folded into this aggregate; empty for a real child.
    let aggregatedChildren: [DiskNode]

    var isOther: Bool { node == nil }

    static func == (lhs: SpaceLensDisplayItem, rhs: SpaceLensDisplayItem) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.itemCount == rhs.itemCount
    }
}

/// Produces the display rows for a folder: its largest children individually,
/// then everything else collapsed into "Other items".
enum SpaceLensChildren {

    /// Sentinel id for the aggregate row.
    static let otherID = AnyHashable("space-lens.other-items")

    /// Display rows for `node`, sorted largest-first. All children are shown —
    /// including zero-byte ones like `.localized`, matching the reference list —
    /// and when there are more than `maxRows` children the smallest fold into a
    /// trailing "Other items" row so the list and chart stay readable.
    static func displayed(for node: DiskNode, maxRows: Int = 8) -> [SpaceLensDisplayItem] {
        let visible = node.children
            .sorted { $0.size > $1.size }
        guard !visible.isEmpty else { return [] }

        guard visible.count > maxRows else {
            return visible.map(item(for:))
        }

        let individual = visible.prefix(maxRows - 1).map(item(for:))
        let remainder = Array(visible.suffix(from: maxRows - 1))
        let otherSize = remainder.reduce(Int64(0)) { $0 + $1.size }
        let otherCount = remainder.reduce(0) { $0 + 1 + $1.itemCount }
        let other = SpaceLensDisplayItem(
            id: otherID,
            name: String(localized: "Other items"),
            size: otherSize,
            itemCount: otherCount,
            node: nil,
            aggregatedChildren: remainder
        )
        return individual + [other]
    }

    private static func item(for node: DiskNode) -> SpaceLensDisplayItem {
        SpaceLensDisplayItem(
            id: AnyHashable(node.id),
            name: node.name,
            size: node.size,
            itemCount: node.itemCount,
            node: node,
            aggregatedChildren: []
        )
    }
}
