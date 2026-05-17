// FullDiskAccessPromptCard.swift
// Inline banner shown in FDA-sensitive scanner idle states when Full Disk Access is missing, so the user gets an actionable prompt instead of silently empty or incomplete scan results.

import SwiftUI
import AppKit

/// Non-blocking inline prompt rendered above a scanner's Scan call-to-action
/// when Full Disk Access has not been granted. The app-wide onboarding sheet
/// (`PermissionOnboardingView`) covers first run; once the user dismisses it
/// with "Continue Without Access" this card is the persistent, per-feature
/// reminder that scans here will be incomplete until access is granted.
///
/// The owning view supplies only the recheck action (typically
/// `AppState.refresh`). Opening System Settings reuses the same deep-link as
/// the onboarding sheet so the Full Disk Access pane URL lives in one place.
struct FullDiskAccessPromptCard: View {

    let onRecheck: () -> Void

    private func openSettings() {
        NSWorkspace.shared.open(PermissionOnboardingViewModel.systemSettingsURL)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.tint)
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
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420)
        .accessibilityIdentifier("fda.inlinePrompt")
    }
}

#Preview {
    FullDiskAccessPromptCard(onRecheck: {})
        .padding()
        .frame(width: 560)
}
