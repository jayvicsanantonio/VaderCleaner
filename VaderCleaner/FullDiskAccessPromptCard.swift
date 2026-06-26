// FullDiskAccessPromptCard.swift
// Inline accent-tinted reminder shown in a scannable section's empty/clean detail state when Full Disk Access is missing, so a user who scanned without access sees why the result looks like "nothing found" and can grant access without leaving the flow.

import SwiftUI
import AppKit

/// Non-blocking inline prompt rendered in a scannable section's empty or clean
/// detail state (System Junk, Large & Old Files, Malware Removal) when Full
/// Disk Access has not been granted. The app-wide onboarding sheet
/// (`PermissionOnboardingView`) covers first run, and the floating Scan button
/// raises a `ScanAccessPopover` at the point of action; this card is the
/// post-scan explanation — it tells a user who scanned anyway why an empty
/// result may just be missing permission, and lets them fix it and re-scan.
///
/// `accent` tints the lock symbol and the primary CTA so the card reads as
/// part of the section it sits in (System Junk green, Large & Old Files teal,
/// etc.). The owning view supplies the recheck action (typically
/// `AppState.refresh`). Opening System Settings reuses the same deep-link as
/// the onboarding sheet so the Full Disk Access pane URL lives in one place.
struct FullDiskAccessPromptCard: View {

    /// Section-aware tint applied to the lock symbol and the primary button.
    /// Defaults to crimson so call sites that don't pass a section accent stay
    /// on the Vader palette without a code change.
    var accent: Color = .vaderCrimson
    let onRecheck: () -> Void

    private func openSettings() {
        NSWorkspace.shared.open(PermissionOnboardingViewModel.systemSettingsURL)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access needed")
                    .font(.callout.weight(.semibold))
                Text("Without it, this scan returns empty or incomplete results. Grant access, then re-check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open System Settings", action: openSettings)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        // Deepen bright section accents so the prominent button
                        // keeps a legible white label rather than the system's
                        // black-on-bright fill.
                        .tint(accent.deepenedForWhite)
                        .accessibilityIdentifier("fda.openSettings")
                    Button("Check Again", action: onRecheck)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("fda.checkAgain")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        // Soft accent halo so the card feels native to the section without
        // overpowering the hero — sits beneath the glass so the surface still
        // reads as a quiet reminder, not an alert.
        .shadow(color: accent.opacity(0.25), radius: 14, y: 4)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("fda.inlinePrompt")
    }
}

#Preview {
    FullDiskAccessPromptCard(accent: .green, onRecheck: {})
        .padding()
        .frame(width: 560)
}
