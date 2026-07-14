// BloomFieldTests.swift
// Unit tests for the bloom cluster's orbit geometry specs, the Core Animation factory that renders them, and the layer-backed view's resting poses.

import XCTest
import AppKit
import SwiftUI
@testable import VaderCleaner

@MainActor
final class BloomFieldTests: XCTestCase {

    // MARK: - Backdrop specs

    func testBackdropCarriesTheThreeDocumentedBlooms() {
        // The primary/secondary/tertiary blooms are the section backdrop's
        // signature: pinned so a refactor can't silently drop one or swap
        // their poses.
        let specs = OrbitingBloomSpec.vaderBackdrop
        XCTAssertEqual(specs.count, 3)

        let primary = specs[0]
        XCTAssertEqual(primary.accentOpacity, 0.45)
        XCTAssertEqual(primary.falloff, 760)
        XCTAssertEqual(primary.anchor, UnitPoint(x: 0.5, y: 0.9))
        XCTAssertEqual(primary.orbitRadius, 160)
        XCTAssertEqual(primary.period, 20)
        XCTAssertTrue(primary.clockwise)

        let secondary = specs[1]
        XCTAssertEqual(secondary.accentOpacity, 0.26)
        XCTAssertEqual(secondary.falloff, 460)
        XCTAssertEqual(secondary.anchor, UnitPoint(x: -0.08, y: 0.3))
        XCTAssertEqual(secondary.orbitRadius, 220)
        XCTAssertEqual(secondary.period, 34)
        XCTAssertFalse(secondary.clockwise)

        let tertiary = specs[2]
        XCTAssertEqual(tertiary.accentOpacity, 0.2)
        XCTAssertEqual(tertiary.falloff, 320)
        XCTAssertEqual(tertiary.anchor, UnitPoint(x: 1.08, y: 0.08))
        XCTAssertEqual(tertiary.orbitRadius, 140)
        XCTAssertEqual(tertiary.period, 14)
        XCTAssertTrue(tertiary.clockwise)
    }

    func testEveryOrbitPeriodIsDistinctSoTheMotionNeverVisiblyRepeats() {
        let periods = OrbitingBloomSpec.vaderBackdrop.map(\.period)
        XCTAssertEqual(Set(periods).count, periods.count)
    }

    // MARK: - Orbit geometry

    private let spec = OrbitingBloomSpec(
        accentOpacity: 0.45,
        falloff: 760,
        anchor: UnitPoint(x: 0.5, y: 0.9),
        orbitRadius: 160,
        period: 20,
        clockwise: true
    )

    func testLayerSideContainsTheFalloffPlusOrbitWithSeamMargin() {
        // The square layer must keep its rectangular bounds outside the
        // gradient's falloff at every rotation angle — a bounds cut inside
        // the falloff shows up as a hard seam when the layer moves.
        XCTAssertEqual(spec.layerSide, 2 * (760 + 160) + 100)
    }

    func testOrbitCentreSitsOneRadiusBelowTheAnchor() {
        let size = CGSize(width: 1320, height: 680)
        let centre = spec.orbitCenter(in: size)
        XCTAssertEqual(centre.x, 1320 * 0.5)
        XCTAssertEqual(centre.y, 680 * 0.9 + 160)
    }

    func testRestingPoseIsExactlyTheAnchor() {
        // The top of the orbit — where a non-animated bloom parks under
        // Reduce Motion — must land on the documented anchor point.
        let size = CGSize(width: 1320, height: 680)
        let resting = spec.restingCenter(in: size)
        XCTAssertEqual(resting.x, 1320 * 0.5)
        XCTAssertEqual(resting.y, 680 * 0.9)
    }

    func testRotationPivotSitsOneOrbitRadiusBelowTheGradientCentre() {
        // The orbit trick: the layer spins about a pivot displaced from the
        // radially-symmetric gradient's centre, so only the circular travel
        // is visible. Unit-space pivot = centre + orbitRadius downward.
        let pivot = spec.rotationAnchorPoint
        XCTAssertEqual(pivot.x, 0.5)
        XCTAssertEqual(pivot.y, 0.5 + 160 / spec.layerSide, accuracy: 0.0001)
    }

    func testGradientFalloffStaysInsideTheLayerBounds() {
        XCTAssertLessThan(spec.gradientEndFraction, 0.5)
        XCTAssertEqual(spec.gradientEndFraction, 760 / spec.layerSide, accuracy: 0.0001)
    }

    // MARK: - Core Animation factory

    func testGradientLayerIsRadialWithTheDocumentedStops() {
        let layer = BloomLayerFactory.gradientLayer(spec: spec, accent: .systemRed)
        XCTAssertEqual(layer.type, .radial)
        XCTAssertEqual(layer.startPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(layer.endPoint.x, 0.5 + spec.gradientEndFraction, accuracy: 0.0001)
        XCTAssertEqual(layer.endPoint.y, 0.5 + spec.gradientEndFraction, accuracy: 0.0001)
        XCTAssertEqual(layer.locations, [0, 0.3, 1])
        XCTAssertEqual(layer.colors?.count, 3)
        XCTAssertEqual(layer.bounds.size, CGSize(width: spec.layerSide, height: spec.layerSide))
        XCTAssertEqual(layer.anchorPoint.y, spec.rotationAnchorPoint.y, accuracy: 0.0001)
    }

    func testGradientAccentStopCarriesTheSpecOpacity() {
        let layer = BloomLayerFactory.gradientLayer(spec: spec, accent: .systemRed)
        guard let colors = layer.colors, colors.count == 3 else {
            return XCTFail("expected three gradient stops")
        }
        let accentStop = colors[1] as! CGColor
        XCTAssertEqual(accentStop.alpha, 0.45, accuracy: 0.001)
    }

    func testOrbitAnimationSpinsOneFullTurnPerPeriodForever() {
        let animation = BloomLayerFactory.orbitAnimation(spec: spec)
        XCTAssertEqual(animation.keyPath, "transform.rotation.z")
        XCTAssertEqual(animation.duration, 20)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertFalse(animation.autoreverses)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(animation.fromValue as? CGFloat, 0)
        XCTAssertEqual(abs(animation.toValue as! CGFloat), 2 * .pi, accuracy: 0.0001)
    }

    func testClockwiseAndCounterClockwiseOrbitsSpinOppositeWays() {
        var counter = spec
        counter.clockwise = false
        let cw = BloomLayerFactory.orbitAnimation(spec: spec).toValue as! CGFloat
        let ccw = BloomLayerFactory.orbitAnimation(spec: counter).toValue as! CGFloat
        XCTAssertEqual(cw, -ccw, accuracy: 0.0001)
    }

    func testBreatheAnimationSwellsOpacityOnTheDocumentedCycle() {
        // The 8-second cycle is offset from every orbit period so the
        // combined motion never visibly repeats.
        let animation = BloomLayerFactory.breatheAnimation()
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, 8)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(animation.fromValue as? Float, 1.0)
        XCTAssertEqual(animation.toValue as? Float, 0.86)
        // CAMediaTimingFunction has no value equality — compare the curve's
        // control points against the named ease-in-ease-out function.
        let expected = CAMediaTimingFunction(name: .easeInEaseOut)
        for index in 0...3 {
            var actualPoint: [Float] = [0, 0]
            var expectedPoint: [Float] = [0, 0]
            animation.timingFunction?.getControlPoint(at: index, values: &actualPoint)
            expected.getControlPoint(at: index, values: &expectedPoint)
            XCTAssertEqual(actualPoint, expectedPoint)
        }
        XCTAssertFalse(
            OrbitingBloomSpec.vaderBackdrop.map(\.period).contains(animation.duration)
        )
    }

    // MARK: - Layer-backed view

    private func makeLaidOutView(animated: Bool) -> BloomFieldNSView {
        let view = BloomFieldNSView(
            specs: OrbitingBloomSpec.vaderBackdrop,
            accent: .systemRed,
            animated: animated
        )
        view.setFrameSize(NSSize(width: 1320, height: 680))
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testViewParksEachBloomAtItsOrbitCentre() {
        let view = makeLaidOutView(animated: true)
        let size = CGSize(width: 1320, height: 680)
        XCTAssertEqual(view.bloomLayers.count, 3)
        for (layer, spec) in zip(view.bloomLayers, OrbitingBloomSpec.vaderBackdrop) {
            XCTAssertEqual(layer.position, spec.orbitCenter(in: size))
        }
    }

    func testAnimatedViewCarriesOrbitAndBreatheAnimations() {
        let view = makeLaidOutView(animated: true)
        for layer in view.bloomLayers {
            XCTAssertNotNil(layer.animation(forKey: BloomFieldNSView.orbitAnimationKey))
        }
        XCTAssertNotNil(view.containerLayer.animation(forKey: BloomFieldNSView.breatheAnimationKey))
    }

    func testReduceMotionViewCarriesNoAnimationsAndRestsAtFullBrightness() {
        let view = makeLaidOutView(animated: false)
        for layer in view.bloomLayers {
            XCTAssertNil(layer.animation(forKey: BloomFieldNSView.orbitAnimationKey))
        }
        XCTAssertNil(view.containerLayer.animation(forKey: BloomFieldNSView.breatheAnimationKey))
        XCTAssertEqual(view.containerLayer.opacity, 1.0)
    }

    func testTurningMotionOffRemovesTheAnimations() {
        let view = makeLaidOutView(animated: true)
        view.setAnimated(false)
        for layer in view.bloomLayers {
            XCTAssertNil(layer.animation(forKey: BloomFieldNSView.orbitAnimationKey))
        }
        XCTAssertNil(view.containerLayer.animation(forKey: BloomFieldNSView.breatheAnimationKey))
    }

    func testAccentUpdateRecoloursEveryBloomsAccentStop() {
        let view = makeLaidOutView(animated: false)
        view.setAccent(.systemBlue)
        for (layer, spec) in zip(view.bloomLayers, OrbitingBloomSpec.vaderBackdrop) {
            guard let colors = layer.colors, colors.count == 3 else {
                return XCTFail("expected three gradient stops")
            }
            let accentStop = colors[1] as! CGColor
            XCTAssertEqual(accentStop.alpha, spec.accentOpacity, accuracy: 0.001)
            let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
            let stop = NSColor(cgColor: accentStop)?.usingColorSpace(.sRGB)
            XCTAssertEqual(stop?.blueComponent ?? 0, blue.blueComponent, accuracy: 0.01)
        }
    }
}
