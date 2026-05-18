// SectionIntroView.swift
// The reusable per-section landing screen: accent-tinted hero, title + tagline, and descriptive sub-feature rows — no Scan button (ContentView floats that separately).

import SwiftUI

/// A scannable section's intro screen. Renders the section's hero, title,
/// one-line tagline, and the descriptive feature rows summarizing what the
/// upcoming scan covers. `presentation.accent` tints only these intro elements
/// — the window's crimson `vaderShell()` is unchanged. The floating Scan
/// button is intentionally NOT here: ContentView adds it so it can float over
/// the window edge.
struct SectionIntroView: View {
    let presentation: SectionPresentation
    let title: String

    // MARK: Accessibility identifiers

    /// Shared by every section's intro so automation can locate "an intro
    /// screen" regardless of which section is showing.
    var rootAccessibilityIdentifier: String { "section.intro" }

    /// Per-section identifier so a test/automation can assert *which* section's
    /// intro is on screen. Derived from the English `title` (the prompt's
    /// "derive from title" option) — stable as long as the English titles are;
    /// Step 6 call sites pass `NavigationSection.title`. Not localized on
    /// purpose: an accessibility *identifier* must not move with the UI
    /// language.
    var sectionAccessibilityIdentifier: String {
        "section.intro.\(titleSlug)"
    }

    /// Stable identifier for the descriptive feature row at `index`.
    func featureAccessibilityIdentifier(at index: Int) -> String {
        "section.intro.feature.\(index)"
    }

    /// Number of descriptive rows this intro renders.
    var featureCount: Int { presentation.features.count }

    /// Lowercased, letters/digits-only reduction of the title, e.g.
    /// "Large & Old Files" → "largeoldfiles".
    private var titleSlug: String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: Body

    var body: some View {
        // Wide layout (hero beside the text) is preferred; ViewThatFits drops
        // to the stacked layout when the detail pane is too narrow for both
        // side by side, so the screen degrades gracefully at the 900pt min
        // window without a manual breakpoint.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 48) {
                hero
                textColumn
            }
            VStack(spacing: 28) {
                hero
                textColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityIdentifier(rootAccessibilityIdentifier)
        .accessibilityElement(children: .contain)
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        Group {
            if let asset = presentation.heroAssetName, !asset.isEmpty {
                // Designer-supplied art is pre-coloured, so it is not accent
                // tinted — only the bloom carries the accent.
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 160)
            } else {
                Image(systemName: presentation.heroSymbol)
                    .font(.system(size: 120))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(presentation.accent)
                    .frame(width: 160, height: 160)
            }
        }
        // Same soft bloom SmartScanIdleState puts behind its hero, recoloured
        // to the section accent so the intro feels like part of one family.
        .shadow(color: presentation.accent.opacity(0.45), radius: 32)
        .accessibilityHidden(true)
    }

    // MARK: Text + features

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(presentation.tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(presentation.features.enumerated()), id: \.offset) { index, feature in
                    featureRow(feature, index: index)
                }
            }
        }
        // Combine the title + tagline + rows under the per-section id without
        // hiding the rows: .contain keeps each row independently queryable by
        // its own identifier while still pinning "this is section X's intro".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(sectionAccessibilityIdentifier)
    }

    /// One descriptive row: accent icon + label. Purely informational — no
    /// checkbox, no action (matches the reference design).
    private func featureRow(_ feature: SectionFeature, index: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(presentation.accent)
                .frame(width: 28, alignment: .center)
            Text(feature.title)
                .font(.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(featureAccessibilityIdentifier(at: index))
    }
}
