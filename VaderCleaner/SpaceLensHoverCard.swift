// SpaceLensHoverCard.swift
// Floating details card the Space Lens treemap and sunburst overlay while the pointer hovers a tile/segment — shows the item's name, size, share of the current folder, and path.

import SwiftUI
import CoreGraphics

/// Small material card surfaced on hover by both Space Lens visualizations.
/// Reports the hovered item's name, formatted size, its share of the folder
/// currently shown, and its path, so the user gets at-a-glance detail without
/// drilling in. Stateless and view-agnostic — the treemap and sunburst each
/// track which node is hovered and feed the values in.
struct SpaceLensHoverCard: View {

    let name: String
    let formattedSize: String
    /// Share of the currently-displayed folder, in `[0, 1]`.
    let fraction: Double
    let path: String

    /// Fixed width the visualizations frame the card to, so the anchor-clamping
    /// math has a known size to keep the card on-canvas.
    static let preferredWidth: CGFloat = 260
    /// Half the card's assumed height, used to clamp its center within the
    /// canvas and to push the card clear of the hovered item. A slight
    /// overestimate is harmless — it just keeps a tall card from being clipped
    /// at the bottom edge.
    static let halfHeight: CGFloat = 48
    /// Breathing room left between the hovered item and the nearest card edge
    /// when the card is placed beside the item.
    static let anchorGap: CGFloat = 8

    /// Clamp the card's center so a card of `preferredWidth` stays fully inside
    /// `bounds`. Anchored to the hovered item, an arc near the edge would
    /// otherwise push the card off-canvas.
    static func clampedCenter(anchor: CGPoint, in bounds: CGSize) -> CGPoint {
        let halfWidth = preferredWidth / 2
        let minX = halfWidth
        let maxX = max(halfWidth, bounds.width - halfWidth)
        let minY = halfHeight
        let maxY = max(halfHeight, bounds.height - halfHeight)
        return CGPoint(
            x: min(max(anchor.x, minX), maxX),
            y: min(max(anchor.y, minY), maxY)
        )
    }

    /// Center for the card describing a treemap tile, placed just above or
    /// below the tile — outside its bounds — so it never covers the pointer,
    /// which sits somewhere inside the tile. Prefers below the tile; flips
    /// above when the card wouldn't fit beneath. The result is clamped on-canvas
    /// (a tile taller than the canvas minus the card can still force overlap, an
    /// accepted edge case).
    static func anchor(forTile rect: CGRect, in bounds: CGSize) -> CGPoint {
        let belowY = rect.maxY + anchorGap + halfHeight
        let aboveY = rect.minY - anchorGap - halfHeight
        let y = belowY + halfHeight <= bounds.height ? belowY : aboveY
        return clampedCenter(anchor: CGPoint(x: rect.midX, y: y), in: bounds)
    }

    /// Center for the card describing a sunburst segment, pushed radially past
    /// the segment's outer edge along its mid-angle. The push includes the
    /// card's support distance in that direction (`|cos|·halfWidth +
    /// |sin|·halfHeight`) so the rectangle clears the arc whatever the angle —
    /// a wide card needs far more clearance toward 3/9 o'clock than 12/6. The
    /// result is clamped on-canvas; on a canvas too small to fit the card beside
    /// the ring the clamp can still pull it back over a side segment, an
    /// accepted edge case.
    static func anchor(
        forSegmentMidAngle midAngle: Double,
        outerRadius: CGFloat,
        center: CGPoint,
        in bounds: CGSize
    ) -> CGPoint {
        let dx = CGFloat(cos(midAngle))
        let dy = CGFloat(sin(midAngle))
        let support = abs(dx) * (preferredWidth / 2) + abs(dy) * halfHeight
        let reach = outerRadius + anchorGap + support
        let anchor = CGPoint(x: center.x + dx * reach, y: center.y + dy * reach)
        return clampedCenter(anchor: anchor, in: bounds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Text(formattedSize)
                    .monospacedDigit()
                Text(Self.percent(fraction))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("space-lens.hoverInfo")
    }

    /// "12.3%". One fraction digit (unlike the whole-percent scan readout) so a
    /// small file or folder still shows a non-zero share on hover.
    private static func percent(_ ratio: Double) -> String {
        let clamped = max(0.0, min(1.0, ratio))
        return clamped.formatted(.percent.precision(.fractionLength(1)))
    }
}

#Preview {
    SpaceLensHoverCard(
        name: "Xcode.app",
        formattedSize: "12.3 GB",
        fraction: 0.214,
        path: "/Applications/Xcode.app"
    )
    .padding()
    .frame(width: 360, height: 160)
}
