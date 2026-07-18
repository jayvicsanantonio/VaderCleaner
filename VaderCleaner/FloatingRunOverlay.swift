// FloatingRunOverlay.swift
// The floating Run disc for Smart Scan's results dashboard — hosted in the same child panel as the Scan disc so it straddles the main window's bottom edge with matching size and position.

import SwiftUI

/// The floating Run button for the Smart Scan results dashboard. Mirrors the
/// shape of `FloatingScanOverlay` so the disc inside the borderless child
/// panel can be either Scan (at `.intro`) or Run (at `.results` with
/// executable work) — same size, same accent, same straddling position. The
/// Run disc has no Full Disk Access popover: FDA was already evaluated when
/// the user kicked off the scan; Run just acts on items the user opted into.
struct FloatingRunOverlay: View {
    var viewModel: SmartScanViewModel
    let section: NavigationSection
    /// Called whenever the disc's results-phase presence changes, so the
    /// owning window controller can order its panel in or out to match.
    var onPresenceChanged: (Bool) -> Void = { _ in }

    /// Section-aware tint shared with the Scan disc so the two surfaces
    /// switch seamlessly without a colour jump.
    private var accent: Color {
        SectionPresentation.for(section)?.accent ?? .vaderCrimson
    }

    /// Whether the disc should currently be on screen — only when the
    /// dashboard is up, at least one selected module would do work, and no
    /// Review (Manager) screen is covering the dashboard.
    private var isShown: Bool {
        viewModel.isRunDiscVisible
    }

    var body: some View {
        Group {
            if isShown {
                FloatingScanButton(
                    title: String(
                        localized: "Fix",
                        comment: "Title on the floating Fix disc shown on the Smart Scan care-plan feed."
                    ),
                    accent: accent,
                    diameter: FloatingScanButton.floatingDiameter,
                    accessibilityIdentifier: "smartScan.run",
                    accessibilityLabel: String(
                        localized: "Fix the included findings",
                        comment: "VoiceOver label for the floating Fix disc on the Smart Scan care-plan feed."
                    ),
                    action: { Task { await viewModel.run() } }
                )
                .transition(.opacity)
            }
        }
        // Fade as the dashboard's hasExecutableWork flips so toggling a
        // tile slides the disc in or out rather than popping.
        .animation(.smooth(duration: 0.35), value: viewModel.phase)
        .animation(.smooth(duration: 0.35), value: isShown)
        .onAppear { onPresenceChanged(isShown) }
        .onChange(of: isShown) { _, newValue in
            onPresenceChanged(newValue)
        }
    }
}
