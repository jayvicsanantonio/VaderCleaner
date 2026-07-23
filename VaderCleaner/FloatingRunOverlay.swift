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
                    action: { Task { await viewModel.requestRun() } }
                )
                // The scope caption floats just above the disc's top edge —
                // within the panel's upper (over-the-window) half — so the disc
                // keeps its exact straddling position while the caption states
                // what one tap will do. It updates live as cards are toggled.
                .overlay(alignment: .top) {
                    RunScopeCaption(
                        freeableBytes: viewModel.freeableBytes,
                        itemCount: viewModel.runnableFindingCount
                    )
                    .alignmentGuide(.top) { dimensions in dimensions.height + 12 }
                    .allowsHitTesting(false)
                }
                .transition(.opacity)
            }
        }
        // Fade as the dashboard's hasExecutableWork flips so toggling a
        // tile slides the disc in or out rather than popping. Animates on
        // the cheap `phaseID` — the payload-carrying `Phase` would drag the
        // whole plan through `Equatable` on every overlay render.
        .animation(.smooth(duration: 0.35), value: viewModel.phaseID)
        .animation(.smooth(duration: 0.35), value: isShown)
        .onAppear { onPresenceChanged(isShown) }
        .onChange(of: isShown) { _, newValue in
            onPresenceChanged(newValue)
        }
    }
}

/// The one-line scope caption above the Fix disc: how much space one tap frees
/// and across how many findings. A solid dark capsule rather than a Liquid
/// Glass material — like the disc, its host panel straddles the window edge, so
/// a material would have no consistent backdrop to tint against.
private struct RunScopeCaption: View {
    let freeableBytes: Int64
    let itemCount: Int

    private var text: String {
        let items = itemCount == 1
            ? String(localized: "1 item", comment: "Fix disc scope caption: a single included finding.")
            : String.localizedStringWithFormat(
                String(localized: "%d items", comment: "Fix disc scope caption: number of included findings."),
                itemCount
            )
        guard freeableBytes > 0 else {
            return String.localizedStringWithFormat(
                String(localized: "%@ ready", comment: "Fix disc scope caption when the run frees no measurable space, e.g. 'App updates ready'."),
                items
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "Frees %@ · %@", comment: "Fix disc scope caption: freeable bytes and item count, e.g. 'Frees 110 GB · 4 items'."),
            CareFindingCopy.formattedBytes(freeableBytes),
            items
        )
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.42))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    )
            )
    }
}
