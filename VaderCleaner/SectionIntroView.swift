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

    /// Cursor position within the intro panel, normalized to (-1, 1) on both
    /// axes with (0, 0) at the panel centre. Drives the 3D hero's parallax
    /// tilt. Resets to `.zero` when the cursor leaves so the hero springs back.
    @State private var cursorOffset: CGPoint = .zero
    /// Size of the intro panel as measured by the hover layer. Cached so the
    /// hover handler can normalize cursor coordinates without re-reading
    /// the geometry on every event.
    @State private var panelSize: CGSize = .zero

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
        // Hover-tracking layer covers the whole intro so the cursor can drive
        // the 3D hero's parallax from anywhere on the panel — not just from
        // directly over the model. Sized via a transparent background
        // GeometryReader so the normalization uses the panel's real bounds.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { panelSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in panelSize = newSize }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard panelSize.width > 0, panelSize.height > 0 else { return }
                            // Map [0, size] → [-1, 1]. Y is flipped so a cursor
                            // above the hero tilts it back (positive X-axis
                            // rotation), matching the natural light direction.
                            let nx = (point.x / panelSize.width) * 2 - 1
                            let ny = (point.y / panelSize.height) * 2 - 1
                            cursorOffset = CGPoint(x: nx, y: ny)
                        case .ended:
                            cursorOffset = .zero
                        }
                    }
            }
        )
        // Seal the intro as a container *before* naming it: applied in this
        // order, `section.intro` labels the container element itself. The
        // reverse order would instead propagate `section.intro` down onto
        // every descendant — overwriting `textColumn`'s own
        // `section.intro.<slug>` identifier so the per-section intro could no
        // longer be located.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rootAccessibilityIdentifier)
    }

    /// Maximum tilt applied to the hero in degrees on each axis when the
    /// cursor is at the panel edge. Subtle enough to read as parallax rather
    /// than a flip.
    private let maxTiltDegrees: Double = 14

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

    /// Real-time 3D rendering of a bundled USDZ via RealityView, with
    /// cursor-tracking parallax tilt. The loaded asset is wrapped in a parent
    /// `Hero` entity that owns the cursor-driven rotation, so the child
    /// entity's own root transform — which carries the Z-up → Y-up axis
    /// conversion Blender's USD exporter bakes in — is never overwritten.
    /// Without the wrapper, setting `hero.transform.rotation` directly on the
    /// loaded entity wipes that conversion and the model renders edge-on.
    /// SwiftUI's own `Model3D` would have been simpler, but it is
    /// `@available(macOS, unavailable)` (visionOS-only) so we drive RealityKit
    /// directly here.
    private func heroModel(named name: String, scale: Double) -> some View {
        ZStack {
            // Symbol only shows if the USDZ actually failed to load — keeps
            // the hero from ever being empty without bleeding through behind
            // a successfully-loaded 3D model.
            if modelLoadFailed {
                heroSymbol
            }

            // TimelineView ticks at the display refresh rate while the view
            // is on screen, forcing RealityView's `update` closure to fire
            // every frame. That lets the slerp inside `update` smoothly ease
            // the entity rotation toward the cursor's target every frame —
            // not just on hover events. Without this, rotation would only
            // change when the cursor moves, and snapping back to identity on
            // cursor-leave would be an instantaneous jump.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                RealityView { content in
                    do {
                        let model = try await Entity(named: name)

                        // Normalize so the largest bounding-box dimension
                        // fills ~85% of RealityView's default camera frustum
                        // on macOS, then multiply by the per-section `scale`
                        // so assets whose composition includes empty space
                        // (e.g. the sparkles cluster) can be boosted without
                        // affecting tightly-packed assets like the trash bin.
                        // We deliberately *don't* add a custom
                        // PerspectiveCamera here: macOS RealityView frames
                        // the scene with its own camera and a custom one
                        // isn't guaranteed to take precedence.
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

                        // Wrapper entity carries the cursor-driven rotation.
                        // The loaded `model` stays untouched as a child,
                        // preserving its Blender-baked axis conversion.
                        let hero = Entity()
                        hero.name = "Hero"
                        hero.addChild(model)
                        content.add(hero)
                        await MainActor.run { modelLoadFailed = false }
                    } catch is CancellationError {
                        // Section-switch invalidation — normal navigation,
                        // not a real load failure.
                    } catch {
                        await MainActor.run { modelLoadFailed = true }
                    }
                } update: { content in
                    guard
                        let hero = content.entities.first(where: { $0.name == "Hero" })
                    else { return }
                    // Target rotation derived from the current cursor offset.
                    let toRad = Float.pi / 180
                    let xAngle = Float(-cursorOffset.y * maxTiltDegrees) * toRad
                    let yAngle = Float(cursorOffset.x * maxTiltDegrees) * toRad
                    let xRot = simd_quatf(angle: xAngle, axis: SIMD3<Float>(1, 0, 0))
                    let yRot = simd_quatf(angle: yAngle, axis: SIMD3<Float>(0, 1, 0))
                    let target = yRot * xRot
                    // Slerp the wrapper's current rotation toward the target
                    // each frame — exponential ease-out, ~0.18 step gives
                    // an ~80ms half-life at 60 fps. Snappy enough to track
                    // the cursor closely, smooth enough that a sudden cursor
                    // leave returns to identity over a few frames instead of
                    // snapping. Apply to the wrapper, never the loaded
                    // model, so the child's Z-up → Y-up axis conversion is
                    // preserved.
                    hero.transform.rotation = simd_slerp(
                        hero.transform.rotation,
                        target,
                        0.18
                    )
                }
                .frame(width: 400, height: 400)
            }
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
