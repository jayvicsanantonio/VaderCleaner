// PermissionOnboardingView.swift
// FDA onboarding sheet — explains why VaderCleaner needs Full Disk Access and links to System Settings.

import SwiftUI

struct PermissionOnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionOnboardingViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Full Disk Access Required")
                .font(.title)
                .fontWeight(.semibold)

            Text(
                "VaderCleaner needs Full Disk Access to scan caches, browser data, " +
                "Mail attachments, Trash on every volume, and other protected locations. " +
                "Without it, scans will return empty or incomplete results."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Label("Open System Settings", systemImage: "1.circle.fill")
                Label("Go to Privacy & Security → Full Disk Access", systemImage: "2.circle.fill")
                Label("Enable VaderCleaner in the list", systemImage: "3.circle.fill")
                Label("Click Check Again to continue", systemImage: "4.circle.fill")
            }
            .font(.callout)
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 8))

            // Shown once the user has been to System Settings and access still
            // reads false — the exact shape of "I already did that, why is this
            // still here". macOS only applies Full Disk Access to a process
            // started after the grant, so re-checking in the same running
            // process keeps failing no matter how many times "Check Again" is
            // clicked; quitting and reopening is what actually picks it up.
            if viewModel.hasVisitedSystemSettings, !appState.hasFullDiskAccess {
                Text(
                    "Still seeing this after Check Again? macOS only applies Full Disk Access the next time VaderCleaner opens — quit and reopen it instead of checking again.",
                    comment: "FDA onboarding sheet: explains why Check Again alone may not detect a grant made while the app was already running."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("permissionOnboarding.restartNote")
            }

            HStack(spacing: 12) {
                Button("Continue Without Access") {
                    viewModel.dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Check Again") {
                    appState.refresh()
                }
                .buttonStyle(.bordered)

                Button("Open System Settings") {
                    viewModel.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        // Named so automation can assert this sheet is *absent* — the
        // first-run flow covers the same permission, and it reappearing after
        // that flow closes is a regression worth catching.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissionOnboarding")
        // Suppress the macOS keyboard focus ring. On appear the first focusable
        // control ("Continue Without Access") would otherwise wear the system's
        // blue halo, matching the Scan-access popover. The buttons stay
        // focusable and operable; only the ring is hidden.
        .focusEffectDisabled()
    }
}

#Preview {
    PermissionOnboardingView()
        .environment(AppState(checker: { false }))
        .environment(PermissionOnboardingViewModel.live())
}
