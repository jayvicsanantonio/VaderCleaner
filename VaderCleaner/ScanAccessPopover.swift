// ScanAccessPopover.swift
// The Full Disk Access gate for the floating Scan button: a pure decision for whether a Scan tap should prompt, plus the popover shown at the point of action.

import SwiftUI

/// What tapping a scannable section's floating Scan button should do, decided
/// purely from the section's FDA sensitivity and the current access state.
///
/// Replaces the always-on inline reminder card: instead of warning on every
/// intro screen, the gate evaluates at the moment the user actually taps Scan.
enum ScanTapOutcome: Equatable {
    /// Start the section's scan immediately.
    case beginScan
    /// Hold the scan and show the Full Disk Access popover first.
    case promptForFullDiskAccess

    /// Pure decision used by the floating Scan button. A scan is gated only
    /// when the section genuinely reads FDA-protected paths *and* access is
    /// missing; every other combination scans straight away.
    static func evaluate(
        requiresFullDiskAccess: Bool,
        hasFullDiskAccess: Bool
    ) -> ScanTapOutcome {
        requiresFullDiskAccess && !hasFullDiskAccess
            ? .promptForFullDiskAccess
            : .beginScan
    }
}

/// Popover anchored to the floating Scan button, shown the moment a user taps
/// Scan on an FDA-sensitive section without access granted. Action-anchored, so
/// it offers an escape hatch ("Scan Anyway") rather than only telling the user
/// to fix the permission — the user asked for a scan, so they can have one.
///
/// `accent` tints the lock symbol and the primary button so the popover reads
/// as part of the section it was raised from (System Junk green, etc.); it
/// defaults to crimson so unspecified call sites stay on the Vader palette.
struct ScanAccessPopover: View {

    /// Section-aware tint applied to the lock symbol and the primary button.
    var accent: Color = .vaderCrimson
    /// Opens System Settings on the Full Disk Access pane.
    let onOpenSettings: () -> Void
    /// Dismisses the popover and starts the scan with whatever is accessible.
    let onScanAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                Text("Full Disk Access needed")
                    .font(.callout.weight(.semibold))
            }
            Text("Without it, this scan can only see unprotected files. Grant access for complete results, or scan what's reachable now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open System Settings", action: onOpenSettings)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityIdentifier("fda.popover.openSettings")
                Button("Scan Anyway", action: onScanAnyway)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("fda.popover.scanAnyway")
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 300)
        // `.contain` keeps the two buttons independently queryable by their
        // own identifiers; without it the container identifier propagates
        // down and overwrites every child's, matching the pattern
        // `SectionIntroView` uses for its per-section / per-feature ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fda.popover")
    }
}

#Preview {
    ScanAccessPopover(accent: .green, onOpenSettings: {}, onScanAnyway: {})
}
