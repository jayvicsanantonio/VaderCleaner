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

    /// Observed for the inline FDA reminder. When access flips on (the user
    /// granted it in System Settings; scenePhase refreshes the flag on
    /// foreground), the card animates out so the intro returns to its
    /// uncluttered landing without a relaunch.
    @EnvironmentObject private var appState: AppState

    /// Localized section title for display. A computed accessor so the
    /// rendered heading tracks the UI language while the identifiers below
    /// stay fixed regardless of locale.
    var title: String { section.title }

    /// Whether the inline Full Disk Access reminder should render for this
    /// section given the supplied access flag. Pulled out as a pure predicate
    /// so tests can pin the behaviour without rendering the body — the only
    /// inputs are `section.requiresFullDiskAccess` and the flag itself.
    func shouldShowFullDiskAccessReminder(hasFullDiskAccess: Bool) -> Bool {
        section.requiresFullDiskAccess && !hasFullDiskAccess
    }

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

    /// Hero + text laid side by side on wide panes, stacked when narrow.
    /// Wrapped in a `ScrollView` so the largest Dynamic Type sizes scroll
    /// instead of clipping; the `minHeight` keyed to the available height
    /// keeps the content vertically centered whenever it still fits, so the
    /// landing looks unchanged at default text sizes.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                // Wide layout (hero beside the text) is preferred;
                // ViewThatFits drops to the stacked layout when the detail
                // pane is too narrow for both side by side, so the screen
                // degrades gracefully at the 900pt min window without a
                // manual breakpoint.
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
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            // No bounce when the content already fits — the intro should feel
            // like a static landing, not a scroll surface, until Dynamic Type
            // actually overflows it.
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier(rootAccessibilityIdentifier)
        .accessibilityElement(children: .contain)
    }

    // MARK: Hero

    /// Designer art when supplied, otherwise the accent-tinted SF Symbol,
    /// behind the shared accent bloom. Decorative — hidden from accessibility.
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
        // A soft bloom behind the hero, recoloured to the section accent so
        // the intro feels like part of one family.
        .shadow(color: presentation.accent.opacity(0.45), radius: 32)
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

    /// Title, tagline, the inline FDA reminder (when needed), and the
    /// descriptive feature rows, grouped under the per-section identifier.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    // Marks the section name as a heading so VoiceOver's
                    // rotor lets users jump straight to it.
                    .accessibilityAddTraits(.isHeader)

                Text(presentation.tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            // Inline reminder, sized to align with the tagline column. Sits
            // between tagline and features so it reads as context for "what
            // this scan can see" rather than an alarm above the title. Slides
            // in/out smoothly when access flips, which is the moment of
            // delight: granting access in System Settings and watching the
            // card retract on return.
            if shouldShowFullDiskAccessReminder(hasFullDiskAccess: appState.hasFullDiskAccess) {
                FullDiskAccessPromptCard(
                    accent: presentation.accent,
                    onRecheck: { appState.refresh() }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    )
                )
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(presentation.features.enumerated()), id: \.offset) { index, feature in
                    featureRow(feature, index: index)
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: appState.hasFullDiskAccess)
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
