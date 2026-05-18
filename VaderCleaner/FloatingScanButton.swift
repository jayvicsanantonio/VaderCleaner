// FloatingScanButton.swift
// The reusable hero call-to-action: a large floating interactive-glass disc with a breathing glow and press feedback, tinted by an accent (crimson by default).

import SwiftUI

/// The hero / dashboard call to action — an interactive-glass disc echoing the
/// reference's circular button. Interactive glass gives it the system
/// press-scale and shimmer; the `accent` tint marks it as the primary action
/// (crimson by default, so unspecified call sites stay on the Vader palette).
/// Shared across sections so every "Scan"/"Clean" CTA stays visually identical.
struct FloatingScanButton: View {
    let title: String
    var accent: Color = .vaderCrimson
    let accessibilityIdentifier: String
    let action: () -> Void

    @State private var hovering = false
    @State private var pulsing = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 108, height: 108)
        }
        .buttonStyle(PressableCircleButtonStyle())
        .glassEffect(
            .regular.tint(accent).interactive(),
            in: .circle
        )
        // Ambient glow that breathes so the primary action keeps drawing the
        // eye even when the rest of the screen is still.
        .shadow(
            color: accent.opacity(pulsing ? 0.65 : 0.4),
            radius: pulsing ? 30 : 18,
            y: 8
        )
        .scaleEffect(hovering ? 1.06 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: hovering)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulsing)
        .onHover { hovering = $0 }
        .onAppear { pulsing = true }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(accessibilityIdentifier)
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
