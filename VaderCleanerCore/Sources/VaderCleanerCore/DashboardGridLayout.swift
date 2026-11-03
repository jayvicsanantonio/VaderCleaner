// DashboardGridLayout.swift
// The bento geometry every section dashboard shares: a lead tile in the first of three columns, and the rest in the other two as a wide tile over rows of pairs.

import CoreGraphics

/// How much room a dashboard tile has, so its card can choose what to show:
/// the lead is tall enough for a centered illustration, a wide tile spans the
/// right-hand column, and a compact tile shares its row with one other.
public enum DashboardTileRole: Equatable, Sendable {
    case lead
    case wide
    case compact
}

/// Where one tile sits in the grid, in the grid's own coordinates.
public struct DashboardGridSlot: Equatable, Sendable {
    public let frame: CGRect
    public let role: DashboardTileRole

    public init(frame: CGRect, role: DashboardTileRole) {
        self.frame = frame
        self.role = role
    }
}

/// Lays out a dashboard's ranked tiles. The pane is divided into three equal
/// columns: the lead takes the first, and the rest fill the other two — the
/// first as a wide tile, the remainder in rows of two. A pair's tiles are each
/// one column wide, so every edge in the grid lines up with the lead's.
///
/// Frames are computed rather than left to nested flexible frames: a deeply
/// flexible grid makes SwiftUI re-probe every card for many candidate sizes on
/// first build, while concrete frames resolve in a single pass.
public enum DashboardGridLayout {

    /// Gap between adjacent tiles, in both directions.
    public static let gap: CGFloat = 16

    public static func slots(count: Int, in size: CGSize, gap: CGFloat = gap) -> [DashboardGridSlot] {
        guard count > 0 else { return [] }
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        guard count > 1 else {
            return [DashboardGridSlot(frame: CGRect(x: 0, y: 0, width: width, height: height), role: .lead)]
        }

        let column = max((width - gap * 2) / 3, 0)
        var slots = [DashboardGridSlot(frame: CGRect(x: 0, y: 0, width: column, height: height), role: .lead)]

        // Origins are clamped to the pane, so one too narrow or short for the
        // gaps collapses its tiles to zero size at the edge instead of placing
        // them outside it.
        let rightX = min(column + gap, width)
        let rightWidth = max(width - rightX, 0)
        let rows = rowSizes(forTilesBesideLead: count - 1)
        let rowHeight = max((height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count), 0)
        let pairWidth = max((rightWidth - gap) / 2, 0)

        for (index, tilesInRow) in rows.enumerated() {
            let y = min(CGFloat(index) * (rowHeight + gap), height)
            if tilesInRow == 1 {
                slots.append(DashboardGridSlot(
                    frame: CGRect(x: rightX, y: y, width: rightWidth, height: rowHeight),
                    role: .wide
                ))
            } else {
                slots.append(DashboardGridSlot(
                    frame: CGRect(x: rightX, y: y, width: pairWidth, height: rowHeight),
                    role: .compact
                ))
                slots.append(DashboardGridSlot(
                    frame: CGRect(x: min(rightX + pairWidth + gap, width), y: y, width: pairWidth, height: rowHeight),
                    role: .compact
                ))
            }
        }
        return slots
    }

    /// How many tiles each right-column row holds: one wide tile first, then
    /// pairs, with any odd one out spanning its row alone.
    private static func rowSizes(forTilesBesideLead count: Int) -> [Int] {
        var rows = [1]
        var remaining = count - 1
        while remaining > 0 {
            let inRow = min(2, remaining)
            rows.append(inRow)
            remaining -= inRow
        }
        return rows
    }
}
