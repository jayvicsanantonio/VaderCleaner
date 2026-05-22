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
    @ObservedObject var controller: ScanDiscWindowController

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
            overlay(controller.smartScanViewModel, .smartScan)
        case .systemJunk:
            overlay(controller.systemJunkViewModel, .systemJunk)
        case .largeOldFiles:
            overlay(controller.largeOldFilesViewModel, .largeOldFiles)
        case .spaceLens:
            overlay(controller.spaceLensViewModel, .spaceLens)
        case .optimization:
            overlay(controller.optimizationViewModel, .optimization)
        case .malwareRemoval:
            overlay(controller.malwareViewModel, .malwareRemoval)
        case .privacy:
            overlay(controller.privacyViewModel, .privacy)
        case .extensions, .appUninstaller, .appUpdater, .healthMonitor:
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
