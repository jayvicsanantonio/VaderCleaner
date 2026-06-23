// ScanDiscHostView.swift
// SwiftUI root hosted inside the Scan disc's child panel — picks the selected section's coordinator, renders the floating disc, and reports its visibility back to the window controller.

import SwiftUI

/// The content of `ScanDiscWindowController`'s child panel. It mirrors the
/// section ContentView is showing (pushed onto `controller.section`) and renders
/// that section's floating Scan disc, centered in the panel.
///
/// Non-scannable sections have no disc; they hide the panel outright so its
/// transparent area never sits over — and intercepts clicks for — the main
/// window.
struct ScanDiscHostView: View {
    var controller: ScanDiscWindowController

    var body: some View {
        content
            // Center the disc within the panel, which is sized larger than the
            // disc so its accent glow is not clipped.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.section {
        case .smartScan:
            // Smart Scan has two discs sharing the panel: the Scan disc at
            // `.intro`, and the Run disc at `.results` with executable work.
            // The wrapper combines their presence so the panel is visible
            // when either disc is showing.
            SmartScanFloatingDisc(
                viewModel: controller.smartScanViewModel,
                onPresenceChanged: { controller.setDiscVisible($0) }
            )
        case .systemJunk:
            overlay(controller.systemJunkViewModel, .systemJunk)
        case .largeOldFiles:
            overlay(controller.myClutterViewModel, .largeOldFiles)
        case .spaceLens:
            overlay(controller.spaceLensViewModel, .spaceLens)
        case .performance:
            overlay(controller.performanceViewModel, .performance)
        case .malwareRemoval:
            overlay(controller.malwareViewModel, .malwareRemoval)
        case .privacy:
            overlay(controller.privacyViewModel, .privacy)
        case .applications:
            overlay(controller.applicationsViewModel, .applications)
        case .healthMonitor:
            // Non-scannable sections never show a disc — keep the panel hidden.
            Color.clear
                .onAppear { controller.setDiscVisible(false) }
        }
    }

    private func overlay<Coordinator: ScanCoordinating>(
        _ coordinator: Coordinator,
        _ section: NavigationSection
    ) -> some View {
        FloatingScanOverlay(
            coordinator: coordinator,
            section: section,
            onIntroPresenceChanged: { controller.setDiscVisible($0) }
        )
    }
}

/// Composes the Smart Scan section's two discs — Scan at `.intro` and Run at
/// `.results` with work — into one overlay, combining their presences with an
/// OR so the host panel is ordered in whenever either disc is showing.
/// Lifted out of the switch so it can hold the per-disc `@State` flags both
/// sub-overlays write to.
private struct SmartScanFloatingDisc: View {
    var viewModel: SmartScanViewModel
    var onPresenceChanged: (Bool) -> Void

    @State private var scanShown = false
    @State private var runShown = false

    var body: some View {
        ZStack {
            FloatingScanOverlay(
                coordinator: viewModel,
                section: .smartScan,
                onIntroPresenceChanged: { shown in
                    scanShown = shown
                    onPresenceChanged(scanShown || runShown)
                }
            )
            FloatingRunOverlay(
                viewModel: viewModel,
                section: .smartScan,
                onPresenceChanged: { shown in
                    runShown = shown
                    onPresenceChanged(scanShown || runShown)
                }
            )
        }
    }
}
