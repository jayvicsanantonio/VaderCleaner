// ManagerChrome.swift
// Shared chrome for the Cleanup-style Manager screens — the accent-tinted nav row, the white light-mode surface, and the magenta manager accent reused by the Cleanup and Performance managers.

import SwiftUI

/// The magenta accent the standalone Manager cards adopt (not a section's own
/// hue). It tints the sort/select values, chevrons, selection, checkboxes, and
/// the footer action so every Manager card reads with one identity.
enum ManagerChrome {
    static let accent = Color(red: 0.81, green: 0.10, blue: 0.55)
    /// The AppKit twin of `accent`, for the recycled item-table row views that
    /// draw their card and hover highlight with `NSColor`.
    static let nsAccent = NSColor(srgbRed: 0.81, green: 0.10, blue: 0.55, alpha: 1)
}

/// A selectable section/category row with the magenta manager selection pill
/// and a quieter hover fill. Every manager's left and middle panes share the one
/// `ManagerChrome.accent` for these active/hover states so they read with a
/// single identity regardless of the section's own hue. Its own view with local
/// hover `@State`, so moving the pointer between rows re-renders only the rows
/// involved — never the whole manager (whose body recomputes per-category sizes
/// and the item table).
struct NavRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content
    @State private var hovered = false

    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? ManagerChrome.accent.opacity(0.22) : (hovered ? ManagerChrome.accent.opacity(0.08) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? ManagerChrome.accent.opacity(0.40) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The card surface behind one interactive row in a Manager's item pane: a
/// white rounded card with a soft shadow and hairline border, matching the
/// AppKit card drawn by `HoverTableRowView`. Deliberately not `glassEffect` —
/// on macOS 26 a glass surface's container view can answer hit-testing itself
/// (instead of the SwiftUI content hosted on it), which left row checkboxes
/// and disclosure buttons unclickable. All the managers that use these rows
/// force the light appearance, so the fixed white fill is safe.
struct ManagerRowCard: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            )
            // A quieter magenta hover fill matching the left/middle nav rows, laid
            // over the white card. Non-hit-testing so it never intercepts the
            // row's checkbox or disclosure control.
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ManagerChrome.accent.opacity(hovered ? 0.08 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
            .onHover { hovered = $0 }
    }
}

extension View {
    /// Styles the view as one Manager row card; see `ManagerRowCard`.
    func managerRowCard() -> some View { modifier(ManagerRowCard()) }
}

/// The rounded checkbox every manager row card uses: an accent-filled rounded
/// square with a white check when on, a softened accent outline when off — the
/// SwiftUI counterpart of `ManagerCheckboxImage` in the AppKit item table, so
/// checkboxes look the same across every list. Colored by the surrounding
/// manager's section accent.
struct ManagerRowCheckbox: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: action) {
            ZStack {
                if isOn {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(accent)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(accent.opacity(0.6), lineWidth: 1.5)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Applies the white, light-mode surface for the standalone Manager cards. A
/// no-op when `light` is false so Smart Scan's managers keep inheriting the
/// section's dark gradient. The `colorScheme` override flips the SwiftUI chrome
/// to dark-on-light; the AppKit item table is switched separately via
/// `ManagerItemTable.forcesLightAppearance`.
struct ManagerSurfaceModifier: ViewModifier {
    let light: Bool

    func body(content: Content) -> some View {
        if light {
            content
                .environment(\.colorScheme, .light)
                .background(Color.white)
                // A big rounded card with an even margin on every side so the
                // window's section gradient shows as a thin border around it.
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .padding(14)
                // Extend up under the title-bar safe area so the top margin is
                // as thin as the sides instead of leaving the toolbar's tall
                // gradient band above the card.
                .ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}
