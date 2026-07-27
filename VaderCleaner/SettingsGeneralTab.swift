// SettingsGeneralTab.swift
// General tab for the Settings window — launch and appearance preferences, permission status rows, and acknowledgements.

import SwiftUI
import AppKit

// MARK: - General tab

struct GeneralTab: View {

    @Environment(PreferencesStore.self) private var preferences
    @Environment(ProtectionSettingsStore.self) private var protectionSettings
    @Environment(SmartScanSettingsStore.self) private var smartScanSettings
    @Environment(CareHistoryStore.self) private var history
    @Environment(AppState.self) private var appState

    @State private var isConfirmingRestore = false
    @State private var isConfirmingClearHistory = false
    @State private var isShowingAcknowledgements = false
    /// The helper's live registration status, re-read whenever the pane appears
    /// so approving it in System Settings reflects without a relaunch.
    @State private var helperStatus = HelperRegistration.currentStatus
    /// Set while a repair is in flight so the button can't be fired twice.
    @State private var isRepairingHelper = false

    /// Marketing version and build from the running bundle, shown in the app
    /// identity header so the About-style info is always accurate.
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(
                symbol: "gearshape",
                title: "General",
                subtitle: "About VaderCleaner, what it's allowed to do, and how it starts up."
            )
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, 6)

            Form {
                Section {
                    identityCard
                }

                Section {
                    AccessStatusRow(
                        symbol: "folder.badge.person.crop",
                        title: "Full Disk Access",
                        status: SettingsAccessStatus.fullDiskAccess(hasAccess: appState.hasFullDiskAccess),
                        isBusy: false,
                        action: openFullDiskAccessSettings
                    )
                    AccessStatusRow(
                        symbol: "wrench.adjustable",
                        title: "Cleanup Helper",
                        status: SettingsAccessStatus.helper(status: helperStatus),
                        isBusy: isRepairingHelper,
                        action: repairHelper
                    )
                } header: {
                    Text("Access")
                } footer: {
                    Text("VaderCleaner needs these to check and clean everything on your Mac. Anything flagged here is worth sorting out — otherwise scans quietly come back with less than they should.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Launch VaderCleaner at login", isOn: $preferences.launchAtLogin)
                } header: {
                    Text("Startup")
                } footer: {
                    Text("VaderCleaner opens quietly in the background when you log in, so it's ready whenever you need it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        isConfirmingClearHistory = true
                    } label: {
                        Label("Clear Scan History…", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(!hasHistory)

                    Button(role: .destructive) {
                        isConfirmingRestore = true
                    } label: {
                        Label("Restore Defaults…", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Your Data")
                } footer: {
                    Text("Everything VaderCleaner records stays on this Mac. Clearing your history forgets what past scans found and how much they freed; restoring defaults puts every setting back the way it came. Your Ignore List is left alone either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        isShowingAcknowledgements = true
                    } label: {
                        Label("Open-Source Licenses…", systemImage: "doc.text")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("VaderCleaner is built on open-source software, including the ClamAV malware engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        // Both capabilities are changed outside the app, in System Settings, so
        // re-read them when the pane appears and again whenever the user comes
        // back to VaderCleaner — otherwise granting access leaves this pane
        // showing the old state until Settings is reopened.
        .onAppear(perform: refreshAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()
        }
        .sheet(isPresented: $isShowingAcknowledgements) {
            AcknowledgementsSheet()
        }
        .confirmationDialog(
            "Clear your scan history?",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VaderCleaner will forget when it last checked your Mac and how much it has freed. Nothing on your Mac is removed, and your settings stay as they are.")
        }
        .confirmationDialog(
            "Restore all settings to their defaults?",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                preferences.restoreDefaults()
                protectionSettings.restoreDefaults()
                smartScanSettings.restoreDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your settings go back to how they started, and this can't be undone. Nothing on your Mac is removed, and your Ignore List stays as it is.")
        }
    }

    // MARK: Identity

    /// App icon, name, version, and — once there's something to show for it —
    /// the lifetime total Smart Scan has freed.
    private var identityCard: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("VaderCleaner")
                    .font(.title3.weight(.semibold))
                Text(versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let freed = history.lifetimeFreedLine() {
                    Text(freed)
                        .font(.callout)
                        .foregroundStyle(Color.settingsAccent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// Whether there is any recorded history to clear — the button stays
    /// disabled on a fresh install rather than offering a no-op.
    private var hasHistory: Bool {
        history.lastScanDate != nil || history.cumulativeBytesFreed > 0 || !history.receipts.isEmpty
    }

    // MARK: Actions

    /// Re-reads both capability states from the system.
    private func refreshAccess() {
        appState.refresh()
        helperStatus = HelperRegistration.currentStatus
    }

    private func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(PermissionOnboardingViewModel.systemSettingsURL)
    }

    /// Re-registers the helper. A fresh registration commonly lands in
    /// `.requiresApproval`, so send the user straight to Login Items when the
    /// repair doesn't land enabled rather than leaving them to find it.
    private func repairHelper() {
        guard !isRepairingHelper else { return }
        isRepairingHelper = true
        Task {
            let status = await HelperRegistration.reregister()
            helperStatus = status
            isRepairingHelper = false
            if status != .enabled {
                HelperRegistration.openLoginItemsSettings()
            }
        }
    }
}

/// One capability row: a health glyph, the capability's name, a plain-language
/// line about what its current state means, and the button that fixes it. The
/// button is absent when there is nothing to fix.
private struct AccessStatusRow: View {

    let symbol: String
    let title: String
    let status: AccessStatusDisplay
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    Image(systemName: status.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isHealthy ? Color.green : Color.orange)
                        .accessibilityLabel(status.isHealthy ? "Working" : "Needs attention")
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle = status.actionTitle {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(actionTitle, action: action)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The bundled open-source license text. Shown as a sheet rather than a link so
/// the terms are readable with no network and no browser.
private struct AcknowledgementsSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open-Source Licenses")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                Text(Acknowledgements.load() ?? "License information isn't available in this build.")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .background(Color(nsColor: .textBackgroundColor))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 420)
    }
}
