// SectionIntroView.swift
// The reusable per-section landing screen: accent-tinted hero, title + tagline, and descriptive sub-feature rows — no Scan button (ContentView floats that separately).

import SwiftUI
import RealityKit

/// A scannable section's intro screen. Renders the section's hero, title,
/// one-line tagline, and the descriptive feature rows summarizing what the
/// upcoming scan covers. `presentation.accent` tints only these intro elements
/// — the window's crimson `vaderShell()` is unchanged. The floating Scan
/// button is intentionally NOT here: ContentView adds it so it can float over
/// the window edge.
struct SectionIntroView: View {
    let presentation: SectionPresentation
    let section: NavigationSection

    /// Localized hero heading for display. Prefers the presentation's
    /// `heroTitle` override (e.g. Cleanup's "Junk Cleanup") and falls back to
    /// the sidebar `section.title`. A computed accessor so the rendered heading
    /// tracks the UI language while the identifiers below stay fixed regardless
    /// of locale.
    var title: String { presentation.heroTitle ?? section.title }

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
        HStack(alignment: .center, spacing: 24) {
            hero
            textColumn
        }
        .padding(.horizontal, 24)
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

    /// Fixed leftward Y-axis rotation applied to every 3D hero so the model
    /// reads as a three-dimensional object rather than a flat icon, without
    /// any cursor-driven motion. Negative rotates the model's +Z front
    /// toward -X, so the model turns its right shoulder toward the camera.
    private let heroLeftTiltDegrees: Double = -22

    // MARK: Hero

    /// USDZ 3D art when supplied (with cursor-tracking parallax tilt),
    /// designer image art when supplied, otherwise the accent-tinted SF
    /// Symbol. All variants share the soft accent orb behind them and the
    /// same VoiceOver treatment as a labelled illustration.
    @ViewBuilder
    private var hero: some View {
        ZStack {
            // A blurred accent orb behind the artwork so the hero glows from
            // within rather than reading as a flat icon. Sized as roughly 2/3
            // of the hero frame so the bloom hugs the model without
            // overflowing into the surrounding panel.
            Circle()
                .fill(presentation.accent.opacity(0.42))
                .frame(width: 280, height: 280)
                .blur(radius: 95)

            heroArtwork
        }
        .frame(width: 400, height: 400)
        // A soft bloom behind the hero, recoloured to the section accent so
        // the intro feels like part of one family.
        .shadow(color: presentation.accent.opacity(0.30), radius: 38)
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

    /// The hero's foreground artwork, picking the richest available
    /// representation: USDZ 3D model > designer image > SF Symbol.
    @ViewBuilder
    private var heroArtwork: some View {
        if let model = presentation.heroModelName, !model.isEmpty {
            heroModel(named: model, scale: presentation.heroModelScale)
        } else if let asset = presentation.heroAssetName, !asset.isEmpty {
            // Designer-supplied art is pre-coloured, so it is not accent
            // tinted — only the bloom carries the accent.
            Image(asset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 336, height: 336)
        } else {
            heroSymbol
        }
    }

    /// Tracks USDZ load outcome so the SF Symbol fallback only shows when the
    /// model actually failed to load — not as a perma-background that bleeds
    /// through the RealityView's transparent canvas.
    @State private var modelLoadFailed: Bool = false

    /// Real-time 3D rendering of a bundled USDZ via RealityView, locked to a
    /// fixed leftward turn so the model reads as a three-dimensional object.
    /// The loaded asset is wrapped in a parent `Hero` entity that owns the
    /// rotation, so the child entity's own root transform — which carries
    /// the Z-up → Y-up axis conversion Blender's USD exporter bakes in — is
    /// never overwritten. Without the wrapper, setting `hero.transform.rotation`
    /// directly on the loaded entity wipes that conversion and the model
    /// renders edge-on. SwiftUI's own `Model3D` would have been simpler, but
    /// it is `@available(macOS, unavailable)` (visionOS-only) so we drive
    /// RealityKit directly here.
    private func heroModel(named name: String, scale: Double) -> some View {
        ZStack {
            // Symbol only shows if the USDZ actually failed to load — keeps
            // the hero from ever being empty without bleeding through behind
            // a successfully-loaded 3D model.
            if modelLoadFailed {
                heroSymbol
            }

            RealityView { content in
                do {
                    let model = try await Entity(named: name)

                    // Normalize so the largest bounding-box dimension fills
                    // ~85% of RealityView's default camera frustum on macOS,
                    // then multiply by the per-section `scale` so assets
                    // whose composition includes empty space (e.g. the
                    // sparkles cluster) can be boosted without affecting
                    // tightly-packed assets like the trash bin. We
                    // deliberately *don't* add a custom PerspectiveCamera
                    // here: macOS RealityView frames the scene with its own
                    // camera and a custom one isn't guaranteed to take
                    // precedence.
                    let bounds = model.visualBounds(relativeTo: nil)
                    let maxExtent = max(
                        bounds.extents.x,
                        bounds.extents.y,
                        bounds.extents.z
                    )
                    if maxExtent > 0 {
                        let normalized: Float = 0.85 / maxExtent
                        model.scale = SIMD3<Float>(repeating: normalized * Float(scale))
                    }
                    // Recenter the loaded model on its parent's origin so
                    // the parent's rotation tilts the model about its own
                    // centre.
                    model.position = -bounds.center * model.scale

                    // Wrapper entity owns the fixed leftward rotation; the
                    // loaded `model` stays untouched as a child so its
                    // Blender-baked axis conversion is preserved.
                    let hero = Entity()
                    hero.name = "Hero"
                    let yAngle = Float(heroLeftTiltDegrees) * (Float.pi / 180)
                    hero.transform.rotation = simd_quatf(
                        angle: yAngle,
                        axis: SIMD3<Float>(0, 1, 0)
                    )
                    hero.addChild(model)
                    content.add(hero)
                    await MainActor.run { modelLoadFailed = false }
                } catch is CancellationError {
                    // Section-switch invalidation — normal navigation,
                    // not a real load failure.
                } catch {
                    await MainActor.run { modelLoadFailed = true }
                }
            }
            .frame(width: 400, height: 400)
            // Force a fresh RealityView per asset so navigating between
            // sections re-runs the `make` closure with the new USDZ instead
            // of reusing the first-loaded entity.
            .id(name)
        }
        .onChange(of: name) { _, _ in modelLoadFailed = false }
    }

    /// Accent-tinted SF Symbol fallback, shared by the no-art path and the
    /// USDZ loading/failure placeholder so all three look identical. Sized
    /// to roughly half the hero frame so the symbol reads as a strong icon
    /// without overflowing the bloom orb behind it.
    private var heroSymbol: some View {
        Image(systemName: presentation.heroSymbol)
            .font(.system(size: 216, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(presentation.accent)
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

            // My Clutter scans a folder the user chooses, so its intro carries
            // a directory selector below the feature rows. Every other section
            // scans fixed system locations and shows no picker.
            if section == .largeOldFiles {
                MyClutterFolderPicker(accent: presentation.accent)
                    .padding(.top, 4)
            }

            // Space Lens scans a whole volume; its intro carries a volume
            // selector so the user can map any mounted drive, not just the boot
            // volume.
            if section == .spaceLens {
                SpaceLensVolumePicker(accent: presentation.accent)
                    .padding(.top, 4)
            }

            // Protection exposes its scan options and mode in Settings; the
            // Configure Scan button routes there directly.
            if section == .malwareRemoval {
                ConfigureScanButton(accent: presentation.accent)
                    .padding(.top, 4)
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
                            presentation.accent.deepenedForWhite,
                            presentation.accent.deepenedForWhite.opacity(0.72),
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
                // Shadow from the same deepened tone as the fill: the raw
                // accent here made the bright-accent sections' badges (green
                // Cleanup, teal My Clutter) cast a vivid halo that read as a
                // bloom, while the deep-accent sections cast a normal dark
                // drop shadow.
                .shadow(color: presentation.accent.deepenedForWhite.opacity(0.4), radius: 7, y: 3)
            Text(feature.title)
                .font(.system(size: 15, weight: .regular))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(featureAccessibilityIdentifier(at: index))
    }
}

/// "Configure Scan" affordance on the Protection intro. Selects the Protection
/// tab and opens the Settings window so the user lands directly on the scan
/// options and scan-mode controls.
private struct ConfigureScanButton: View {
    let accent: Color

    @Environment(\.openSettings) private var openSettings
    @Environment(SettingsRouter.self) private var router

    var body: some View {
        Button {
            router.selectedTab = .protectionScan
            openSettings()
        } label: {
            Label("Configure Scan", systemImage: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.bordered)
        .tint(accent)
        .accessibilityIdentifier("section.intro.configureScan")
    }
}
