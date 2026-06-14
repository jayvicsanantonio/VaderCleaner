// NavigationRailView.swift
// Custom sidebar rail: one focusable button per NavigationSection with a soft glass selection pill and quieter hover highlight.

import SwiftUI
import AppKit

/// A custom rail of buttons (not a List) so selection can be a soft inset
/// glass pill with generous spacing instead of the system's full-bleed
/// selection bar. The rail and the detail share one continuous gradient — no
/// sidebar material, no divider. Arrow-key navigation between rows is
/// intentionally not reimplemented (it was a `List` affordance); the rows are
/// focusable buttons, so Tab / Space / Return and VoiceOver still work.
struct NavigationRailView: View {
    /// The currently active section, drawn with the lit selection pill. `nil`
    /// renders the rail with no pill at all.
    let selectedSection: NavigationSection?
    /// Invoked when the user taps a row. The parent owns the actual selection
    /// state and any transition bookkeeping; the rail just reports the tap.
    let onSelect: (NavigationSection) -> Void

    /// The section the pointer is currently over, if any. Drives the rail's
    /// hover highlight — a quieter pill than the selection's.
    @State private var hoveredSection: NavigationSection?
    /// Namespace for the sliding selection pill.
    @Namespace private var pillNamespace

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(NavigationSection.allCases) { section in
                    railRow(section)
                }
            }
            .padding(.horizontal, 10)
            // The content extends under the hidden title bar, so inset the
            // first row clear of the window's traffic-light controls. The top
            // and bottom insets, the row gap, and the row height are tuned
            // together so all eleven rows fit a default-height window without
            // scrolling.
            .padding(.top, 58)
            .padding(.bottom, 12)
        }
        // No scroll indicator: at a typical window height the eleven rows sit
        // statically with no visible scrolling. The ScrollView is retained so
        // the bottom rows stay reachable when a short window or a larger
        // Dynamic Type size overflows the column.
        .scrollIndicators(.hidden)
        // Anchor the rail to the true window top. Detail screens declare
        // different toolbars, which changes the window's top safe-area inset;
        // without this the rail would ride that inset and shift vertically
        // between sections. The `.padding(.top, 58)` above clears the
        // traffic-light controls measured from this fixed top.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The rail glyph for a section: its monochrome relief icon when one
    /// exists, so the rail matches the section's hero art; otherwise the SF
    /// Symbol (Health Monitor ships no bespoke art). The glyph is a neutral
    /// light-gray relief — multiplying it by the accent lights the
    /// active/hovered row while preserving the 3D shading, and the inactive
    /// state stays a dimmed gray, mirroring the symbol's neutral→accent
    /// treatment.
    @ViewBuilder
    private func railIcon(_ section: NavigationSection, isActive: Bool) -> some View {
        if let asset = section.railIconAssetName {
            railGlyph(asset, isActive: isActive, accent: section.theme.accent)
        } else {
            Image(systemName: section.icon)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                // The symbol stays neutral — matching the inactive label —
                // until the row is active or hovered, when it lights up in
                // the section's accent.
                .foregroundStyle(isActive ? section.theme.accent : Color.white.opacity(0.62))
                .frame(width: 26)
        }
    }

    /// Renders a monochrome rail glyph. An active/hovered row tints it with a
    /// vertical accent gradient — a lightened accent at the top fading to a
    /// deeper accent at the bottom — multiplied over the relief and clipped to
    /// the glyph so the 3D shading shows through. Inactive rows stay a dimmed
    /// flat gray, mirroring the symbol's neutral→accent treatment.
    @ViewBuilder
    private func railGlyph(_ asset: String, isActive: Bool, accent: Color) -> some View {
        let glyph = Image(asset)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 26, height: 26)
        if isActive {
            glyph
                .overlay {
                    LinearGradient(
                        colors: [shade(accent, 0.62), shade(accent, -0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.multiply)
                }
                .mask { glyph }
        } else {
            glyph
                .colorMultiply(Color(white: 0.82))
                .opacity(0.85)
        }
    }

    /// Lightens (`amount > 0`, toward white) or darkens (`amount < 0`, toward
    /// black) a colour for the active glyph's gradient stops.
    private func shade(_ color: Color, _ amount: Double) -> Color {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 1)
        let r = Double(ns.redComponent), g = Double(ns.greenComponent), b = Double(ns.blueComponent)
        if amount >= 0 {
            let t = amount
            return Color(.sRGB, red: r * (1 - t) + t, green: g * (1 - t) + t, blue: b * (1 - t) + t)
        } else {
            let t = -amount
            return Color(.sRGB, red: r * (1 - t), green: g * (1 - t), blue: b * (1 - t))
        }
    }

    private func railRow(_ section: NavigationSection) -> some View {
        let isSelected = selectedSection == section
        let isHovering = hoveredSection == section
        return Button {
            onSelect(section)
        } label: {
            HStack(spacing: 14) {
                railIcon(section, isActive: isSelected || isHovering)
                Text(section.title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected || isHovering ? Color.white : Color.white.opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background {
                if isSelected {
                    // A translucent pill — the dark page shows through, lifted
                    // by a soft horizontal sheen that is brightest at the left
                    // and right edges and dims behind the label in the centre.
                    // No accent tint: a saturated glass fill reads as a solid
                    // button, not the see-through surface the reference uses.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.22),
                                    .white.opacity(0.07),
                                    .white.opacity(0.22),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            // A hairline rim in the section's accent, brightest
                            // along the leading edge and fading across to the
                            // trailing edge, so the active pill reads as a lit,
                            // colour-keyed glass surface.
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            section.theme.accent.opacity(0.85),
                                            section.theme.accent.opacity(0.25),
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .matchedGeometryEffect(id: "selectionPill", in: pillNamespace)
                } else if isHovering {
                    // Hover highlight — a quieter pill than the selection: a
                    // fainter flat fill and a dim hairline border, no top-lit
                    // sheen, so the hover and active states stay clearly
                    // distinct.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle())
        // Suppress the macOS keyboard focus ring. Without this the first
        // focusable row wears the system's blue halo on launch; the rail's
        // selection pill is its own state indicator.
        .focusEffectDisabled()
        // Track the pointer so the row can show its hover highlight. Clearing
        // only when *this* section is the one being left avoids a stale value
        // when the pointer crosses straight from one row to the next.
        .onHover { hovering in
            if hovering {
                hoveredSection = section
            } else if hoveredSection == section {
                hoveredSection = nil
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityIdentifier(section.accessibilityIdentifier)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Button style for the rail rows that renders the label with no pressed-state
/// treatment. The system `.plain` style dims the whole label — including the
/// selection pill, which lives inside it — on press; re-clicking the already
/// active row (a no-op for selection) then shows only that dim-and-restore,
/// reading as a flicker. The lit pill and the hover highlight are the row's
/// feedback instead, so suppressing the press dim is purely a visual win.
private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
