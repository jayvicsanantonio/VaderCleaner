// MyClutterThumbnailStripItem.swift
// One selectable image in the Duplicates / Similar Images thumbnail strip: a removal checkbox, the kept-original badge, and magenta active/hover states.

import SwiftUI

/// Which emphasis a thumbnail draws, highest priority first: a selected image
/// (marked for removal) always shows the active magenta border, then the
/// focused image (the one shown in the large preview), then a hovered one, then
/// idle. Pure so the precedence stays unit-testable without rendering.
enum ClutterThumbnailEmphasis {
    case selected
    case focused
    case hovered
    case idle

    static func resolve(isSelected: Bool, isFocused: Bool, hovered: Bool) -> ClutterThumbnailEmphasis {
        if isSelected { return .selected }
        if isFocused { return .focused }
        if hovered { return .hovered }
        return .idle
    }
}

/// One image in the Duplicates / Similar Images thumbnail strip: a selectable
/// card with a removal checkbox (top-left), the kept-original badge (top-right),
/// a magenta border when selected (active), and a light-magenta hover tint. Its
/// own view with local hover state so moving the pointer repaints only the
/// hovered thumbnail, not the whole preview pane. The checkbox toggles removal
/// selection; tapping elsewhere on the image focuses it in the large preview.
struct ClutterThumbnailStripItem: View {
    let url: URL
    let isOriginal: Bool
    let showsBestBadge: Bool
    let isSelected: Bool
    let isFocused: Bool
    let accent: Color
    let onToggleSelect: () -> Void
    let onFocus: () -> Void

    @State private var hovered = false

    private var emphasis: ClutterThumbnailEmphasis {
        ClutterThumbnailEmphasis.resolve(isSelected: isSelected, isFocused: isFocused, hovered: hovered)
    }

    var body: some View {
        ClutterThumbnailView(url: url, fallbackSymbol: "photo")
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Light-magenta hover tint, non-hit-testing so it never intercepts
            // the checkbox tap or the focus tap beneath it.
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(hovered ? 0.14 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .overlay(alignment: .topLeading) { checkbox }
            .overlay(alignment: .topTrailing) { badge }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: onFocus)
            .onHover { hovered = $0 }
    }

    // A white chip behind the shared manager checkbox keeps it legible over a
    // busy photo, matching the checkbox used by the file-list rows.
    private var checkbox: some View {
        ManagerRowCheckbox(isOn: isSelected, action: onToggleSelect)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.85))
            )
            .padding(4)
    }

    @ViewBuilder
    private var badge: some View {
        if showsBestBadge && isOriginal {
            Circle().fill(.green).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .padding(5)
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .selected: return accent
        case .focused:  return accent.opacity(0.55)
        case .hovered:  return accent.opacity(0.40)
        case .idle:     return Color.secondary.opacity(0.25)
        }
    }

    private var borderWidth: CGFloat {
        switch emphasis {
        case .selected:         return 2.5
        case .focused:          return 1.5
        case .hovered, .idle:   return 1
        }
    }
}
