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
    let section: NavigationSection

    /// Localized section title for display. A computed accessor so the
    /// rendered heading tracks the UI language while the identifiers below
    /// stay fixed regardless of locale.
    var title: String { section.title }

    // MARK: Accessibility identifiers

    /// Shared by every section's intro so automation can locate "an intro
    /// screen" regardless of which section is showing.
    var rootAccessibilityIdentifier: String { "section.intro" }

    /// Per-section identifier so a test/automation can assert *which* section's
    /// intro is on screen. Derived from the `NavigationSection` case name —
    /// not the localized title — so the identifier is identical in every
    /// locale. An accessibility *identifier* must not move with the UI
    /// language or UI automation breaks when the app is run translated.
    var sectionAccessibilityIdentifier: String {
        "section.intro.\(sectionSlug)"
    }

    /// Stable identifier for the descriptive feature row at `index`.
    func featureAccessibilityIdentifier(at index: Int) -> String {
        "section.intro.feature.\(index)"
    }

    /// Number of descriptive rows this intro renders.
    var featureCount: Int { presentation.features.count }

    /// Locale-independent slug from the enum case name, e.g.
    /// `.largeOldFiles` → "largeoldfiles".
    private var sectionSlug: String {
        String(describing: section).lowercased()
    }

    // MARK: Body

    /// Hero and text laid side by side, centred in the pane above the floating
    /// Scan disc. No `ScrollView`: the landing is a single static composition,
    /// kept compact so it fits without scrolling, and the bottom inset reserves
    /// a clear band for the Scan disc so the two never collide.
    var body: some View {
        HStack(alignment: .center, spacing: 44) {
            hero
            textColumn
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reserve the bottom band for the floating Scan disc, so the centred
        // cluster sits clear of it and the landing never needs to scroll.
        .padding(.bottom, 168)
        // Seal the intro as a container *before* naming it: applied in this
        // order, `section.intro` labels the container element itself. The
        // reverse order would instead propagate `section.intro` down onto
        // every descendant — overwriting `textColumn`'s own
        // `section.intro.<slug>` identifier so the per-section intro could no
        // longer be located.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rootAccessibilityIdentifier)
    }

    // MARK: Hero

    /// Designer art when supplied, otherwise the accent-tinted SF Symbol,
    /// over a soft accent orb. Decorative — hidden from accessibility.
    @ViewBuilder
    private var hero: some View {
        ZStack {
            // A blurred accent orb behind the artwork so the hero glows from
            // within rather than reading as a flat icon.
            Circle()
                .fill(presentation.accent.opacity(0.42))
                .frame(width: 132, height: 132)
                .blur(radius: 50)

            if let asset = presentation.heroAssetName, !asset.isEmpty {
                // Designer-supplied art is pre-coloured, so it is not accent
                // tinted — only the bloom carries the accent.
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 168, height: 168)
            } else {
                Image(systemName: presentation.heroSymbol)
                    .font(.system(size: 108, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(presentation.accent)
            }
        }
        .frame(width: 200, height: 200)
        // A soft bloom behind the hero, recoloured to the section accent so
        // the intro feels like part of one family.
        .shadow(color: presentation.accent.opacity(0.30), radius: 22)
        // The art is decorative, but a sighted user gets a clear section
        // anchor here, so VoiceOver gets one too. The label is qualified as
        // an "illustration" rather than the bare section name so it does not
        // read as a verbatim duplicate of the section-title heading that
        // follows — it announces the artwork, the heading announces the
        // section.
        .accessibilityElement()
        .accessibilityLabel(Text(String(
            localized: "\(title) illustration",
            comment: "VoiceOver label for a section intro's decorative hero art, e.g. \"System Junk illustration\"."
        )))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Text + features

    /// Title, tagline, and the descriptive feature rows, grouped under the
    /// per-section identifier.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 40, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    // Marks the section name as a heading so VoiceOver's
                    // rotor lets users jump straight to it.
                    .accessibilityAddTraits(.isHeader)

                Text(presentation.tagline)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(presentation.features.enumerated()), id: \.offset) { index, feature in
                    featureRow(feature, index: index)
                }
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        // Combine the title + tagline + rows under the per-section id without
        // hiding the rows: .contain keeps each row independently queryable by
        // its own identifier while still pinning "this is section X's intro".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(sectionAccessibilityIdentifier)
    }

    /// One descriptive row: an accent badge + label. Purely informational — no
    /// checkbox, no action (matches the reference design).
    private func featureRow(_ feature: SectionFeature, index: Int) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            presentation.accent,
                            presentation.accent.opacity(0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
                .shadow(color: presentation.accent.opacity(0.4), radius: 7, y: 3)
            Text(feature.title)
                .font(.system(size: 15, weight: .regular))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(featureAccessibilityIdentifier(at: index))
    }
}
