// BloomField.swift
// Layer-backed bloom cluster behind VaderBackground — orbiting accent glows and the slow breathe, animated by Core Animation on the render server so an idle window costs no per-frame main-thread work.

import SwiftUI
import AppKit
import QuartzCore

// MARK: - Orbit geometry

/// One accent bloom on a circular path: a radial glow displaced off the pivot
/// of an oversized square layer that spins forever — the orbit trick. The
/// gradient is radially symmetric, so the rotation itself is invisible; only
/// the circular travel shows.
///
/// A pure value type so every derived measurement — layer side, orbit centre,
/// resting pose, pivot — is unit-testable without a view or a window. All
/// points are in top-left-origin (flipped) coordinates, matching both SwiftUI
/// and the flipped `BloomFieldNSView` that renders the specs.
struct OrbitingBloomSpec: Equatable {
    /// Opacity applied to the section accent for this bloom's glow.
    var accentOpacity: CGFloat
    /// Radius at which the glow fades to fully clear.
    var falloff: CGFloat
    /// Resting pose in window space — the top of the orbit, and where the
    /// bloom stays when the orbit is not animated (Reduce Motion).
    var anchor: UnitPoint
    /// Radius of the circular path.
    var orbitRadius: CGFloat
    /// Seconds per revolution.
    var period: Double
    /// Direction of travel around the circle.
    var clockwise: Bool

    /// Side of the square layer the bloom is drawn on. Must contain the whole
    /// falloff plus the orbit displacement, so the layer's rectangular bounds
    /// always sit in the gradient's fully-clear region — a bounds cut inside
    /// the falloff shows up as a hard seam when the layer moves.
    var layerSide: CGFloat { 2 * (falloff + orbitRadius) + 100 }

    /// The pivot the layer spins about, in the hosting view's coordinates.
    /// It sits one radius below the anchor, so the path's top — and the
    /// Reduce Motion resting pose — is exactly the anchor.
    func orbitCenter(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * anchor.x,
            y: size.height * anchor.y + orbitRadius
        )
    }

    /// Where the gradient's centre rests at rotation zero: the anchor itself.
    func restingCenter(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * anchor.x,
            y: size.height * anchor.y
        )
    }

    /// The rotation pivot in the layer's unit space: the gradient centre
    /// displaced one orbit radius downward (+y in flipped geometry).
    var rotationAnchorPoint: CGPoint {
        CGPoint(x: 0.5, y: 0.5 + orbitRadius / layerSide)
    }

    /// The gradient's end circle as a fraction of the layer side. Always under
    /// 0.5 because `layerSide` pads past the falloff.
    var gradientEndFraction: CGFloat { falloff / layerSide }

    /// The three blooms behind every section. All anchors hug (or overshoot)
    /// the window edges so only a partial arc of each glow is ever visible —
    /// the light reads as a wash coming in from the edge, never as a
    /// travelling circle.
    static let vaderBackdrop: [OrbitingBloomSpec] = [
        // Primary bloom — the section's classic glow, low on the bottom edge
        // where it still pools behind the floating Scan disc.
        OrbitingBloomSpec(
            accentOpacity: 0.45,
            falloff: 760,
            anchor: UnitPoint(x: 0.5, y: 0.9),
            orbitRadius: 160,
            period: 20,
            clockwise: true
        ),
        // Secondary bloom — dimmer, wider orbit, counter-rotating just past
        // the left edge so it swells in and out of the window as it circles.
        OrbitingBloomSpec(
            accentOpacity: 0.26,
            falloff: 460,
            anchor: UnitPoint(x: -0.08, y: 0.3),
            orbitRadius: 220,
            period: 34,
            clockwise: false
        ),
        // Tertiary bloom — small and faint in the upper-right corner, on the
        // fastest lap, adding a third phase.
        OrbitingBloomSpec(
            accentOpacity: 0.2,
            falloff: 320,
            anchor: UnitPoint(x: 1.08, y: 0.08),
            orbitRadius: 140,
            period: 14,
            clockwise: true
        ),
    ]
}

// MARK: - Core Animation factory

/// Builds the gradient layers and render-server animations the bloom view
/// hosts. Split from the view so every layer property and animation parameter
/// is assertable in unit tests without a window.
enum BloomLayerFactory {

    /// The radial glow for one bloom. A white-hot core inside the accent
    /// glow: on themes whose accent sits close to the backdrop hue (Health
    /// Monitor's blue on blue), a pure accent bloom moves almost invisibly —
    /// the bright core is what keeps the motion legible on every section's
    /// palette.
    static func gradientLayer(spec: OrbitingBloomSpec, accent: NSColor) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.colors = gradientColors(spec: spec, accent: accent)
        layer.locations = [0, 0.3, 1]
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(
            x: 0.5 + spec.gradientEndFraction,
            y: 0.5 + spec.gradientEndFraction
        )
        layer.bounds = CGRect(x: 0, y: 0, width: spec.layerSide, height: spec.layerSide)
        // Spinning about the off-centre pivot is what carries the bloom
        // around its path — see `OrbitingBloomSpec.rotationAnchorPoint`.
        layer.anchorPoint = spec.rotationAnchorPoint
        return layer
    }

    /// The three gradient stops for a bloom in `accent`'s hue. Separated so a
    /// theme change can recolour an existing layer without rebuilding it.
    static func gradientColors(spec: OrbitingBloomSpec, accent: NSColor) -> [CGColor] {
        [
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07).cgColor,
            accent.withAlphaComponent(spec.accentOpacity).cgColor,
            NSColor.clear.cgColor,
        ]
    }

    /// One full revolution per period, forever, paced linearly. Runs on the
    /// render server: once added, the app's main thread does no per-frame
    /// work to keep the orbit moving.
    ///
    /// The hosting view is flipped, so its backing layer renders with flipped
    /// geometry — a positive z-rotation (counter-clockwise in the layer's own
    /// maths) appears clockwise on screen.
    static func orbitAnimation(spec: OrbitingBloomSpec) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        let fullTurn = 2 * CGFloat.pi
        animation.fromValue = CGFloat(0)
        animation.toValue = spec.clockwise ? fullTurn : -fullTurn
        animation.duration = spec.period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A slow breathe over the whole cluster: brightness swells and relaxes
    /// on a cycle offset from every orbit period, so the combined motion
    /// never visibly repeats. Applied to the cluster's container layer and,
    /// like the orbits, animated by the render server.
    static func breatheAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = Float(1.0)
        animation.toValue = Float(0.86)
        animation.duration = 8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

// MARK: - Layer-backed view

/// Hosts the bloom cluster's layers. Flipped so its coordinates match the
/// top-left-origin space the specs are written in; never draws any view
/// content itself — the render server composites the gradient layers and
/// drives their animations without main-thread involvement.
final class BloomFieldNSView: NSView {

    static let orbitAnimationKey = "orbit"
    static let breatheAnimationKey = "breathe"

    /// Holds the blooms so the breathe can dim the whole cluster with one
    /// opacity animation, mirroring the previous SwiftUI `.opacity` over the
    /// cluster's ZStack.
    let containerLayer = CALayer()
    private(set) var bloomLayers: [CAGradientLayer] = []

    private let specs: [OrbitingBloomSpec]
    private var accent: NSColor
    private var isAnimated: Bool

    init(specs: [OrbitingBloomSpec], accent: NSColor, animated: Bool) {
        self.specs = specs
        self.accent = accent
        self.isAnimated = animated
        super.init(frame: .zero)

        wantsLayer = true
        // The view renders nothing of its own — all content is sublayers.
        layerContentsRedrawPolicy = .never
        // The blooms deliberately overhang the window edges; nothing clips.
        containerLayer.masksToBounds = false
        layer?.masksToBounds = false
        layer?.addSublayer(containerLayer)

        for spec in specs {
            let bloom = BloomLayerFactory.gradientLayer(spec: spec, accent: accent)
            containerLayer.addSublayer(bloom)
            bloomLayers.append(bloom)
        }
        applyAnimations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BloomFieldNSView is built in code")
    }

    override var isFlipped: Bool { true }

    /// Re-park each bloom's pivot for the current size. Positions are pure
    /// layout, never animated — the implicit-action transaction guard keeps a
    /// window resize from lagging the blooms behind the edges they hug.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = bounds
        for (bloom, spec) in zip(bloomLayers, specs) {
            bloom.position = spec.orbitCenter(in: bounds.size)
        }
        CATransaction.commit()
    }

    /// Recolours the glow for a new section accent without rebuilding layers.
    func setAccent(_ newAccent: NSColor) {
        guard newAccent != accent else { return }
        accent = newAccent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bloom, spec) in zip(bloomLayers, specs) {
            bloom.colors = BloomLayerFactory.gradientColors(spec: spec, accent: newAccent)
        }
        CATransaction.commit()
    }

    /// Starts or parks the ambient motion. Parking removes every animation so
    /// Reduce Motion leaves the blooms at their resting poses at full
    /// brightness — the layers' model values, which the animations never
    /// touched.
    func setAnimated(_ animated: Bool) {
        guard animated != isAnimated else { return }
        isAnimated = animated
        applyAnimations()
    }

    private func applyAnimations() {
        if isAnimated {
            for (bloom, spec) in zip(bloomLayers, specs) where bloom.animation(forKey: Self.orbitAnimationKey) == nil {
                bloom.add(BloomLayerFactory.orbitAnimation(spec: spec), forKey: Self.orbitAnimationKey)
            }
            if containerLayer.animation(forKey: Self.breatheAnimationKey) == nil {
                containerLayer.add(BloomLayerFactory.breatheAnimation(), forKey: Self.breatheAnimationKey)
            }
        } else {
            for bloom in bloomLayers {
                bloom.removeAnimation(forKey: Self.orbitAnimationKey)
            }
            containerLayer.removeAnimation(forKey: Self.breatheAnimationKey)
        }
    }
}

// MARK: - SwiftUI bridge

/// The bloom cluster as a SwiftUI view, sized by its container the way the
/// previous GeometryReader-driven cluster was. `VaderBackground` layers it
/// over the section gradient.
struct BloomField: NSViewRepresentable {
    /// The active section's accent colour, before per-bloom opacity.
    let accent: Color
    /// False parks every bloom at its anchor (Reduce Motion).
    let animated: Bool

    func makeNSView(context: Context) -> BloomFieldNSView {
        BloomFieldNSView(
            specs: OrbitingBloomSpec.vaderBackdrop,
            accent: NSColor(accent),
            animated: animated
        )
    }

    func updateNSView(_ nsView: BloomFieldNSView, context: Context) {
        nsView.setAccent(NSColor(accent))
        nsView.setAnimated(animated)
    }
}
