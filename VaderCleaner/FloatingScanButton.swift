// FloatingScanButton.swift
// The reusable hero call-to-action: a large circular accent-filled disc with a white ring, a breathing glow, and press feedback.

import SwiftUI
import AppKit

/// The hero / dashboard call to action — a circular button echoing the
/// reference's Scan disc. A saturated `accent` fill (crimson by default, so
/// unspecified call sites stay on the Vader palette) marks it as the primary
/// action, and a white ring lifts it off the backdrop. Shared across sections
/// so every "Scan"/"Clean" CTA stays visually identical.
///
/// The fill is a solid colour rather than a Liquid Glass material on purpose:
/// the floating Scan disc is hosted in a child panel that straddles the window
/// edge, so for its lower half there is no window backdrop for glass to tint
/// against — a glass disc reads as dark grey over the desktop.
struct FloatingScanButton: View {

    /// Diameter of the floating Scan disc. Shared as one constant so the disc,
    /// its host panel, and the panel's placement maths all agree on one size.
    static let floatingDiameter: CGFloat = 130

    let title: String
    var accent: Color = .vaderCrimson
    /// Diameter of the circular button. Defaults to the compact size used by
    /// in-window CTAs such as the Smart Scan "Clean" button; the floating Scan
    /// disc passes `floatingDiameter`.
    var diameter: CGFloat = 108
    let accessibilityIdentifier: String
    /// VoiceOver label. `nil` falls back to `title` so existing call sites
    /// keep announcing "Scan"; the scan-centric shell passes
    /// "Scan <Section>" so each section's disc is distinguishable.
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The label VoiceOver will announce — the caller's override, or the
    /// visible title when none was supplied. Exposed so the contract is
    /// unit-testable without rendering.
    var resolvedAccessibilityLabel: String { accessibilityLabel ?? title }

    /// White ring width, scaled to the disc so it stays proportionate.
    private var borderWidth: CGFloat { max(1.5, diameter * 0.018) }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: diameter * 0.17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                // An opaque accent fill darkened toward the centre by a radial
                // black-to-clear wash, so the white title sits on a deeper
                // backdrop and stays legible while the rim keeps the vivid
                // section colour. The wash only darkens — it never fades to
                // transparent — so the disc still reads as solid where it
                // floats over the desktop, beyond any window backdrop glass
                // could tint against.
                .background(
                    Circle()
                        .fill(accent)
                        .overlay(
                            Circle().fill(
                                RadialGradient(
                                    colors: [.black.opacity(0.55), .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: diameter * 0.5
                                )
                            )
                        )
                )
                // Crisp white ring, echoing the reference's lit disc.
                .overlay(
                    Circle().strokeBorder(.white, lineWidth: borderWidth)
                )
                // The frame is only transparent layout padding around the
                // text; without an explicit content shape the button's hit
                // region would collapse to the glyphs. Make the whole circle
                // the tappable surface.
                .contentShape(Circle())
        }
        .buttonStyle(PressableCircleButtonStyle())
        // Ambient accent glow that breathes so the primary action keeps drawing
        // the eye even when the rest of the screen is still. The glow is a
        // fixed-radius blurred disc whose *opacity* pulses: animating opacity
        // composites the cached blur on the GPU, whereas animating a shadow's
        // blur radius — the earlier approach — forced the gaussian blur to be
        // re-rasterized every frame for as long as the disc was on screen.
        // The pulse itself is a Core Animation opacity animation on a
        // layer-backed host (see PulsingGlowDisc below) so the render server
        // drives it — a SwiftUI `repeatForever` here kept the hosting view in
        // a per-frame render loop for as long as the disc was on screen.
        .background {
            PulsingGlowDisc(accent: accent, diameter: diameter, animated: !reduceMotion)
                .frame(
                    width: diameter + 2 * GlowPulse.blurBleedMargin,
                    height: diameter + 2 * GlowPulse.blurBleedMargin
                )
                .offset(y: 8)
                .allowsHitTesting(false)
        }
        .scaleEffect(hovering ? 1.06 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(resolvedAccessibilityLabel)
    }
}

/// Press feedback for the circular CTAs — a quick spring scale-down while
/// pressed so the button feels physical rather than flat.
private struct PressableCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

// MARK: - Glow pulse

/// Parameters and the render-server animation for the disc's breathing glow.
/// Split from the view so the cycle is assertable in unit tests.
enum GlowPulse {
    /// The glow's brightness between pulses — and its fixed brightness when
    /// Reduce Motion parks the breathe.
    static let restingOpacity: Float = 0.4
    /// The brightness the breathe swells to.
    static let peakOpacity: Float = 0.65
    /// Seconds per half-cycle (dim → bright).
    static let period: Double = 1.8
    /// Canvas padding around the disc so the 24pt gaussian blur's tail is
    /// never clipped by the hosting view's bounds.
    static let blurBleedMargin: CGFloat = 72

    /// The breathe as a Core Animation opacity animation. Once added, the
    /// render server drives it — the main thread does no per-frame work to
    /// keep the glow alive.
    static func pulseAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = restingOpacity
        animation.toValue = peakOpacity
        animation.duration = period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

/// The glow disc itself — the same SwiftUI blurred circle as ever, rendered
/// once into a hosting view whose *layer* opacity breathes via Core
/// Animation. The SwiftUI content is static, so no per-frame render loop.
final class PulsingGlowDiscView: NSView {

    static let pulseAnimationKey = "pulse"

    private let hosting: NSHostingView<GlowDiscContent>
    private var isAnimated: Bool

    init(accent: NSColor, diameter: CGFloat, animated: Bool) {
        hosting = NSHostingView(rootView: GlowDiscContent(accent: Color(nsColor: accent), diameter: diameter))
        isAnimated = animated
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        // The resting brightness is the layer's model value; the pulse
        // animates above it and removal falls back to it.
        layer?.opacity = GlowPulse.restingOpacity
        // Opt out of intrinsic-size plumbing: the representable's frame is
        // authoritative, and letting the hosting view push size constraints
        // would re-enter window layout for a purely decorative backdrop.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        applyAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PulsingGlowDiscView is built in code")
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    /// Recolours the glow for a new accent without rebuilding the view.
    func setAccent(_ accent: NSColor, diameter: CGFloat) {
        let content = GlowDiscContent(accent: Color(nsColor: accent), diameter: diameter)
        if hosting.rootView != content {
            hosting.rootView = content
        }
    }

    /// Starts or parks the breathe. Parking removes the animation so Reduce
    /// Motion leaves the glow at its resting brightness.
    func setAnimated(_ animated: Bool) {
        guard animated != isAnimated else { return }
        isAnimated = animated
        applyAnimation()
    }

    private func applyAnimation() {
        if isAnimated {
            if layer?.animation(forKey: Self.pulseAnimationKey) == nil {
                layer?.add(GlowPulse.pulseAnimation(), forKey: Self.pulseAnimationKey)
            }
        } else {
            layer?.removeAnimation(forKey: Self.pulseAnimationKey)
        }
    }
}

/// The static SwiftUI content of the glow: the accent disc under its fixed
/// 24pt blur, centred in the padded canvas the caller sizes.
struct GlowDiscContent: View, Equatable {
    let accent: Color
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: diameter, height: diameter)
            .blur(radius: 24)
    }
}

/// SwiftUI bridge for the glow. The caller gives it the padded canvas frame;
/// accent and Reduce Motion changes update the existing view in place.
private struct PulsingGlowDisc: NSViewRepresentable {
    let accent: Color
    let diameter: CGFloat
    let animated: Bool

    func makeNSView(context: Context) -> PulsingGlowDiscView {
        PulsingGlowDiscView(accent: NSColor(accent), diameter: diameter, animated: animated)
    }

    func updateNSView(_ nsView: PulsingGlowDiscView, context: Context) {
        nsView.setAccent(NSColor(accent), diameter: diameter)
        nsView.setAnimated(animated)
    }
}
