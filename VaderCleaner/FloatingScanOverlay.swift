// FloatingScanOverlay.swift
// The floating Scan disc for one scannable section — shown only at the `.intro` phase, accent-tinted, and gated behind the Full Disk Access popover when access is missing.

import SwiftUI
import AppKit

/// The floating Scan button for one scannable section. Observes the coordinator
/// so the disc is shown only while the section is at `.intro` and vanishes the
/// moment a scan starts. Accent-tinted per section.
///
/// Hosted inside `ScanDiscWindowController`'s child panel so the disc can
/// straddle the main window's bottom edge. `onIntroPresenceChanged` reports
/// whether the disc is currently on screen so the controller can show or hide
/// that panel in step.
struct FloatingScanOverlay<Coordinator: ScanCoordinating>: View {
    let coordinator: Coordinator
    let section: NavigationSection
    /// Called whenever the disc's `.intro`-phase presence changes, so the
    /// owning window controller can order its panel in or out to match.
    var onIntroPresenceChanged: (Bool) -> Void = { _ in }

    /// Observed so a Scan tap can be gated on the live Full Disk Access flag.
    @Environment(AppState.self) private var appState
    /// Armed when the user starts a scan here, so its completion notifies.
    @Environment(ScanCompletionNotifier.self) private var scanCompletionNotifier

    /// Drives the Full Disk Access popover anchored to the Scan disc. Set true
    /// when the user taps Scan on an FDA-sensitive section without access; the
    /// scan is held until they choose "Open System Settings" or "Scan Anyway".
    @State private var showFullDiskAccessPrompt = false

    /// Section-aware tint shared by the disc and the popover raised from it.
    private var accent: Color {
        SectionPresentation.for(section)?.accent ?? .vaderCrimson
    }

    /// Whether the disc should currently be on screen.
    private var isAtIntro: Bool {
        coordinator.scanPresentation == .intro
    }

    var body: some View {
        Group {
            if isAtIntro {
                FloatingScanButton(
                    title: String(localized: "Scan", comment: "Floating scan button title."),
                    accent: accent,
                    diameter: FloatingScanButton.floatingDiameter,
                    accessibilityIdentifier: section.scanAccessibilityIdentifier,
                    accessibilityLabel: String(
                        localized: "Scan \(section.title)",
                        comment: "VoiceOver label for a section's floating scan button, e.g. \"Scan System Junk\"."
                    ),
                    action: handleScanTap
                )
                .transition(.opacity)
                // The Full Disk Access warning is anchored to the disc and
                // raised only at the moment of action — tapping Scan on an
                // FDA-sensitive section without access — so it never sits as
                // permanent furniture on the intro screen.
                .popover(isPresented: $showFullDiskAccessPrompt, arrowEdge: .top) {
                    ScanAccessPopover(
                        accent: accent,
                        onOpenSettings: {
                            // Dismiss the popover before handing focus to
                            // System Settings so no stale popover lingers when
                            // the app comes back forward.
                            showFullDiskAccessPrompt = false
                            NSWorkspace.shared.open(PermissionOnboardingViewModel.systemSettingsURL)
                        },
                        onScanAnyway: {
                            showFullDiskAccessPrompt = false
                            startScan()
                        }
                    )
                }
            }
        }
        // The disc fades out as the section leaves `.intro` instead of
        // popping, staying in lock-step with the intro → detail crossfade.
        .animation(.smooth(duration: 0.35), value: coordinator.scanPresentation)
        .onAppear { onIntroPresenceChanged(isAtIntro) }
        .onChange(of: coordinator.scanPresentation) { _, _ in
            onIntroPresenceChanged(isAtIntro)
        }
    }

    /// Routes a Scan tap: FDA-sensitive sections without access raise the
    /// access popover; everything else starts the scan immediately.
    private func handleScanTap() {
        switch ScanTapOutcome.evaluate(
            requiresFullDiskAccess: section.requiresFullDiskAccess,
            hasFullDiskAccess: appState.hasFullDiskAccess
        ) {
        case .beginScan:
            startScan()
        case .promptForFullDiskAccess:
            showFullDiskAccessPrompt = true
        }
    }

    /// Arms the completion notification for this section, then starts the scan.
    /// Both user-facing Scan paths (the disc tap and "Scan Anyway") route here so
    /// the "scan finished" banner only fires for scans the user initiated.
    private func startScan() {
        scanCompletionNotifier.armScan(section: section, coordinator: coordinator)
        coordinator.beginScan()
    }
}
