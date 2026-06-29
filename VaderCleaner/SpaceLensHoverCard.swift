// SpaceLensHoverCard.swift
// Floating details card the Space Lens bubble chart overlays while the pointer hovers a bubble — shows the item's name, category, size, item count, and last-modified date, placed beside the bubble so it never covers the cursor.

import SwiftUI
import CoreGraphics

/// Small material card surfaced on hover by the Space Lens bubble chart. Reports
/// the hovered item's name, its category ("System folder" / "Folder" / "File"),
/// formatted size, descendant count, and last-modified date — the at-a-glance
/// detail the reference UI shows. Stateless: the bubble view tracks which node
/// is hovered and feeds the values in.
struct SpaceLensHoverCard: View {

    let name: String
    /// Display category, e.g. "System folder". Tinted with the warning color
    /// when `categoryIsProtected` so protected items read as off-limits.
    let category: String
    let categoryIsProtected: Bool
    let formattedSize: String
    let itemCount: Int
    let modificationDate: Date?
    /// Running removal selection totals, shown as a trailing "Selected:" line
    /// when anything is selected (matching the reference card).
    var selectedCount: Int = 0
    var selectedSize: Int64 = 0

    /// Fixed width the bubble view frames the card to, so the anchor-clamping
    /// math has a known size to keep the card on-canvas.
    static let preferredWidth: CGFloat = 260
    /// Half the card's assumed height, used to clamp its center within the
    /// canvas and to push the card clear of the hovered bubble. A slight
    /// overestimate is harmless — it just keeps a tall card from being clipped.
    static let halfHeight: CGFloat = 52
    /// Breathing room left between the hovered bubble and the nearest card edge.
    static let anchorGap: CGFloat = 8

    /// Clamp the card's center so a card of `preferredWidth` stays fully inside
    /// `bounds`. A bubble near the edge would otherwise push the card off-canvas.
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

    /// Center for the card describing a bubble whose bounding box is `rect`,
    /// placed just above or below the bubble — outside its bounds — so it never
    /// covers the pointer inside the bubble. Prefers below; flips above when the
    /// card wouldn't fit beneath. Clamped on-canvas.
    static func anchor(forTile rect: CGRect, in bounds: CGSize) -> CGPoint {
        let belowY = rect.maxY + anchorGap + halfHeight
        let aboveY = rect.minY - anchorGap - halfHeight
        let y = belowY + halfHeight <= bounds.height ? belowY : aboveY
        return clampedCenter(anchor: CGPoint(x: rect.midX, y: y), in: bounds)
    }

    /// "Jun 1, 2026 at 1:34 PM" — the medium-date / short-time form the
    /// reference card uses. Exposed for tests.
    static func formattedModified(_ date: Date?) -> String? {
        guard let date else { return nil }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(category)
                .font(.caption.weight(.medium))
                .foregroundStyle(categoryIsProtected ? Color(red: 1.0, green: 0.74, blue: 0.27) : Color.white.opacity(0.7))
            Text("Size: \(formattedSize)  |  \(Self.itemsLabel(itemCount))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            if let modified = Self.formattedModified(modificationDate) {
                Text(String(localized: "Modified: \(modified)"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            if selectedCount > 0 {
                Text("Selected: \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .binary))  |  \(Self.itemsLabel(selectedCount))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(red: 0.96, green: 0.45, blue: 0.85))
            }
        }
        .padding(12)
        .frame(maxWidth: Self.preferredWidth, alignment: .leading)
        .background(Color(red: 0.10, green: 0.08, blue: 0.16).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("space-lens.hoverInfo")
    }

    /// "155 items" / "1 item".
    private static func itemsLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
    }
}

#Preview {
    SpaceLensHoverCard(
        name: "Shared",
        category: "System folder",
        categoryIsProtected: true,
        formattedSize: "809 KB",
        itemCount: 155,
        modificationDate: Date()
    )
    .padding()
    .frame(width: 360, height: 160)
}
