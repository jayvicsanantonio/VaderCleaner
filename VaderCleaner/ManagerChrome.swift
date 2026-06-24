// ManagerChrome.swift
// Shared chrome for the Cleanup-style Manager screens — the accent-tinted nav row, the white light-mode surface, and the magenta manager accent reused by the Cleanup and Performance managers.

import SwiftUI

/// The magenta accent the standalone Manager cards adopt (not a section's own
/// hue). It tints the sort/select values, chevrons, selection, checkboxes, and
/// the footer action so every Manager card reads with one identity.
enum ManagerChrome {
    static let accent = Color(red: 0.81, green: 0.10, blue: 0.55)
}

/// A selectable section/category row with the section-accent selection pill and
/// a quieter hover fill. Its own view with local hover `@State`, so moving the
/// pointer between rows re-renders only the rows involved — never the whole
/// manager (whose body recomputes per-category sizes and the item table).
struct NavRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content
    @Environment(\.sectionAccent) private var accent
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
                        .fill(selected ? accent.opacity(0.22) : (hovered ? accent.opacity(0.08) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? accent.opacity(0.40) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
