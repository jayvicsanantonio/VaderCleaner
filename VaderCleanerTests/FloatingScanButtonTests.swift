// FloatingScanButtonTests.swift
// Pins the reusable FloatingScanButton contract: stored title/accent/accessibility identifier and that triggering it invokes the supplied action.

import XCTest
import SwiftUI
@testable import VaderCleaner

@MainActor
final class FloatingScanButtonTests: XCTestCase {

    func test_exposesPassedAccessibilityIdentifier() {
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.accessibilityIdentifier,
            "section.scan",
            "FloatingScanButton must surface the accessibility identifier it was given"
        )
    }

    func test_storesPassedTitle() {
        let button = FloatingScanButton(
            title: "Clean",
            accessibilityIdentifier: "section.clean",
            action: {}
        )

        XCTAssertEqual(button.title, "Clean")
    }

    func test_invokesActionOnTrigger() {
        var fired = false
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: { fired = true }
        )

        XCTAssertFalse(fired, "Action must not fire on construction")

        button.action()

        XCTAssertTrue(fired, "Triggering the button must invoke the supplied action")
    }

    func test_defaultAccentIsVaderCrimson() {
        // The default keeps existing SmartScan call sites visually unchanged
        // after the extraction — they pass no accent and must stay crimson.
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.accent,
            .vaderCrimson,
            "FloatingScanButton must default its tint to VaderTheme crimson"
        )
    }

    func test_customAccentIsStored() {
        let button = FloatingScanButton(
            title: "Scan",
            accent: .blue,
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.accent,
            .blue,
            "A caller-supplied accent must override the crimson default"
        )
    }

    func test_defaultDiameterIsCompact() {
        // In-window CTAs (e.g. the Smart Scan "Clean" button) pass no diameter
        // and must keep the compact size.
        let button = FloatingScanButton(
            title: "Clean",
            accessibilityIdentifier: "section.clean",
            action: {}
        )

        XCTAssertEqual(button.diameter, 108)
    }

    func test_customDiameterIsStored() {
        let button = FloatingScanButton(
            title: "Scan",
            diameter: 150,
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(button.diameter, 150)
    }

    func test_floatingDiameterIsLargerThanTheCompactDefault() {
        // The floating Scan disc is deliberately a lot bigger than the
        // in-window default so it reads as the screen's hero action.
        let compact = FloatingScanButton(
            title: "Clean",
            accessibilityIdentifier: "section.clean",
            action: {}
        )

        XCTAssertGreaterThan(
            FloatingScanButton.floatingDiameter,
            compact.diameter,
            "The floating Scan disc must be larger than the compact CTA default"
        )
    }

    func test_accessibilityLabelDefaultsToTitle() {
        // Call sites that don't pass a label keep VoiceOver announcing the
        // visible title, so the disc still reads as "Scan" by default.
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.scan",
            action: {}
        )

        XCTAssertEqual(
            button.resolvedAccessibilityLabel,
            "Scan",
            "Without an explicit label the button must fall back to its title"
        )
    }

    func test_customAccessibilityLabelOverridesTitle() {
        // The scan-centric shell passes "Scan <Section>" so VoiceOver
        // distinguishes one section's disc from another.
        let button = FloatingScanButton(
            title: "Scan",
            accessibilityIdentifier: "section.systemJunk.scan",
            accessibilityLabel: "Scan System Junk",
            action: {}
        )

        XCTAssertEqual(
            button.resolvedAccessibilityLabel,
            "Scan System Junk",
            "A caller-supplied accessibility label must override the title"
        )
    }

    // MARK: - Glow pulse

    func test_pulseAnimationBreathesOpacityOnTheDocumentedCycle() {
        // The 1.8s opacity breathe between the resting and peak values,
        // running forever on the render server — the main thread does no
        // per-frame work to keep the glow alive.
        let animation = GlowPulse.pulseAnimation()
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, 1.8)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(animation.fromValue as? Float, GlowPulse.restingOpacity)
        XCTAssertEqual(animation.toValue as? Float, GlowPulse.peakOpacity)
    }

    func test_pulseSpansTheOriginalOpacityRange() {
        // Pinned to the values the SwiftUI implementation breathed between,
        // so the CA-driven glow reads identically.
        XCTAssertEqual(GlowPulse.restingOpacity, 0.4)
        XCTAssertEqual(GlowPulse.peakOpacity, 0.65)
    }

    func test_animatedGlowViewCarriesThePulse() {
        let view = PulsingGlowDiscView(accent: .systemRed, diameter: 130, animated: true)
        XCTAssertNotNil(view.layer?.animation(forKey: PulsingGlowDiscView.pulseAnimationKey))
    }

    func test_reduceMotionGlowRestsAtTheDimOpacityWithNoPulse() {
        // Honouring Reduce Motion: the glow parks at its resting brightness
        // rather than breathing.
        let view = PulsingGlowDiscView(accent: .systemRed, diameter: 130, animated: false)
        XCTAssertNil(view.layer?.animation(forKey: PulsingGlowDiscView.pulseAnimationKey))
        XCTAssertEqual(view.layer?.opacity, GlowPulse.restingOpacity)
    }

    func test_turningMotionOffRemovesThePulse() {
        let view = PulsingGlowDiscView(accent: .systemRed, diameter: 130, animated: true)
        view.setAnimated(false)
        XCTAssertNil(view.layer?.animation(forKey: PulsingGlowDiscView.pulseAnimationKey))
    }
}
