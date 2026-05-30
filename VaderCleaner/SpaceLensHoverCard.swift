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
    /// Half the card's assumed height, used only to clamp its center within the
    /// canvas. A slight overestimate is harmless — it just keeps a tall card
    /// from being clipped at the bottom edge.
    private static let halfHeight: CGFloat = 48

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
