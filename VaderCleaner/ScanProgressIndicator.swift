// ScanProgressIndicator.swift
// A section-tinted animated scan indicator — a glowing core with sonar pulses and counter-rotating arcs — used in place of the plain system spinner on every scan/clean-in-progress screen.

import SwiftUI

/// Animated, section-tinted stand-in for `ProgressView` on the app's
/// scan/clean-in-progress screens. A soft accent bloom, three expanding "sonar"
/// pulses, two counter-rotating gradient arcs, and a pulsing core read as an
/// active scan in the app's glow language — giving the in-progress state
/// personality without leaving the section's palette.
///
/// The tint defaults to the active section accent from the environment (set by
/// `vaderShell`), so each section's loader matches its window backdrop with no
/// per-call wiring. Honors Reduce Motion: the spin and sonar drop to a calm,
/// static glowing emblem.
struct ScanProgressIndicator: View {
    /// Overall diameter; every element scales from this.
    var size: CGFloat = 132
    /// Explicit tint override. `nil` uses the active section accent so the
    /// loader matches the backdrop it sits on.
    var accent: Color? = nil

    @Environment(\.sectionAccent) private var sectionAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    private var tint: Color { accent ?? sectionAccent }

    var body: some View {
        ZStack {
            bloom
            if !reduceMotion { sonar }
            arcs
            core
        }
        .frame(width: size, height: size)
        .onAppear { animating = true }
        // The adjacent status label carries the meaning; the art is decorative.
        .accessibilityHidden(true)
    }

    /// Soft accent halo that breathes behind the rest.
    private var bloom: some View {
        Circle()
            .fill(tint.opacity(0.30))
            .blur(radius: size * 0.22)
            .scaleEffect(animating ? 1.05 : 0.8)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: animating
            )
    }

    /// Three rings that expand out of the core and fade, staggered so a new
    /// pulse leaves as the last one dissolves — the "scanning" read.
    private var sonar: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(tint.opacity(0.45), lineWidth: 1.5)
                    .scaleEffect(animating ? 1.0 : 0.25)
                    .opacity(animating ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 2.6)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.85),
                        value: animating
                    )
            }
        }
    }

    /// Two trimmed gradient arcs at different radii, spinning in opposite
    /// directions so the indicator reads as active machinery.
    private var arcs: some View {
        ZStack {
            arc(trim: 0.62, lineWidth: 4, inset: 0, clockwise: true, duration: 1.4)
            arc(trim: 0.40, lineWidth: 3, inset: size * 0.16, clockwise: false, duration: 2.0)
        }
    }

    private func arc(trim: CGFloat, lineWidth: CGFloat, inset: CGFloat, clockwise: Bool, duration: Double) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [tint.opacity(0), tint]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .padding(inset)
            .rotationEffect(.degrees(animating ? (clockwise ? 360 : -360) : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: duration).repeatForever(autoreverses: false),
                value: animating
            )
    }

    /// Glowing core that pulses at the centre.
    private var core: some View {
        Circle()
            .fill(tint)
            .frame(width: size * 0.12, height: size * 0.12)
            .shadow(color: tint.opacity(0.9), radius: size * 0.07)
            .scaleEffect(animating ? 1.18 : 0.85)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: animating
            )
    }
}

#Preview {
    ScanProgressIndicator(accent: Color(red: 0.78, green: 0.25, blue: 0.98))
        .frame(width: 320, height: 320)
        .background(Color.black)
}
