// SettingsNotificationsTab.swift
// Notifications tab for the Settings window — per-event delivery toggles and the system authorization state.

import SwiftUI
import AppKit

// MARK: - Notifications tab

struct NotificationsTab: View {

    @Environment(PreferencesStore.self) private var preferences
    @Environment(NotificationSettingsModel.self) private var notifications

    /// Picker option sets for the inline dropdowns.
    private let trashSizeOptions = [1, 2, 5, 10, 20]
    private let diskFreeOptions = [5, 10, 25, 50, 100, 200]

    var body: some View {
        @Bindable var preferences = preferences
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
                SettingsPaneHeader(
                    symbol: "bell",
                    title: "Notifications",
                    subtitle: "Choose what VaderCleaner should give you a heads-up about."
                )

                permissionRow

                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                section("Smart Scan") {
                    toggleRow("Remind me to run a Smart Scan", isOn: $preferences.remindSmartCare) {
                        Picker("", selection: $preferences.smartCareFrequency) {
                            ForEach(SmartCareFrequency.allCases) { freq in
                                Text(freq.label).tag(freq)
                            }
                        }
                    }
                    Toggle("Tell me when a scan finishes", isOn: $preferences.notifyScanFinished)
                }

                section("Disk Space") {
                    toggleRow("Warn me when free space drops below", isOn: $preferences.notifyLowDisk) {
                        Picker("", selection: $preferences.diskFreeThresholdGB) {
                            ForEach(diskFreeOptions, id: \.self) { gb in
                                Text("\(gb) GB").tag(gb)
                            }
                        }
                    }
                    toggleRow("Tell me when my Trash grows past", isOn: $preferences.notifyTrashSize) {
                        Picker("", selection: $preferences.trashSizeThresholdGB) {
                            ForEach(trashSizeOptions, id: \.self) { gb in
                                Text("\(gb) GB").tag(gb)
                            }
                        }
                    }
                    Toggle("Tell me when I plug in a drive", isOn: $preferences.notifyDriveConnected)
                    Toggle("Offer to free up space on nearly full drives", isOn: $preferences.notifyOverfilledDrives)
                }

                section("Mac Health") {
                    Toggle("Warn me when my Mac is running low on memory", isOn: $preferences.notifyHighRAM)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Tell me when an app stops responding", isOn: $preferences.notifyHungApps)
                        caption("When an app freezes, VaderCleaner gives you an easy way to close it.")
                    }
                    Toggle("Warn me when a connected device's battery is low", isOn: $preferences.notifyDeviceBatteryLow)
                }

                section("Protection") {
                    Toggle("Tell me right away if malware turns up", isOn: $preferences.notifyMalwareFound)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Warn me when malware definitions are out of date", isOn: $preferences.notifyDefinitionsStale)
                        caption("Old definitions can't recognise the newest threats, so scans quietly come back cleaner than they should.")
                    }
                }

                section("Apps & Files") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Tell me when app updates are available", isOn: $preferences.notifyAppUpdates)
                        caption("VaderCleaner checks once a day. Turning this off stops the checks entirely.")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Offer to remove apps completely", isOn: $preferences.offerUninstallOnTrash)
                        caption("Dragging an app to the Trash leaves its files behind. VaderCleaner will offer to clear those out too.")
                    }
                    Toggle("Tell me when large or forgotten files turn up", isOn: $preferences.notifyLargeFilesFound)
                }

                section("Sound") {
                    Toggle("Play a sound with alerts", isOn: $preferences.notificationSoundsEnabled)
                    caption("VaderCleaner won't repeat the same alert more than once every few minutes, however many are switched on above.")
                }
                }
            }
            .toggleStyle(.settingsCheckbox)
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, SettingsMetrics.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The system's decision changes outside the app, so re-read it on
            // appear and whenever the user comes back to VaderCleaner.
            .task { await notifications.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await notifications.refresh() }
            }
        }
    }

    /// Whether macOS is actually letting VaderCleaner through, plus the fix and
    /// a way to prove delivery works. Sits above the toggles because when this
    /// is unhealthy, none of them do anything.
    private var permissionRow: some View {
        let status = NotificationAccessStatus.display(for: notifications.authorizationStatus)
        // Centered rather than top-aligned: unlike the General tab's access
        // rows, this one has no title above its detail line, so the glyph and
        // the button belong on the text's centre — including when a longer
        // state wraps to two lines.
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: status.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isHealthy ? Color.green : Color.orange)
                .font(.system(size: 15))
                .accessibilityLabel(status.isHealthy ? "Alerts allowed" : "Alerts blocked")

            Text(status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle = status.actionTitle {
                Button(actionTitle) {
                    if NotificationAccessStatus.canRequestPermission(for: notifications.authorizationStatus) {
                        Task { await notifications.requestPermission() }
                    } else {
                        NSWorkspace.shared.open(NotificationAccessStatus.systemSettingsURL)
                    }
                }
            } else {
                Button("Send a Test") { notifications.sendTest() }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(status.isHealthy
                      ? Color(nsColor: .textBackgroundColor).opacity(0.5)
                      : Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(status.isHealthy
                              ? Color(nsColor: .separatorColor)
                              : Color.orange.opacity(0.5))
        )
    }

    /// One category: a bold title in a fixed leading column with the category's
    /// toggle rows stacked beside it, matching the reference layout.
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(title)
                .font(.headline)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            Spacer(minLength: 0)
        }
    }

    /// A checkbox row with an inline dropdown sized to its content, so the picker
    /// sits just after the label as in the reference. The picker disables when
    /// the toggle is off.
    @ViewBuilder
    private func toggleRow(
        _ title: String,
        isOn: Binding<Bool>,
        @ViewBuilder picker: () -> some View
    ) -> some View {
        HStack(spacing: 14) {
            Toggle(title, isOn: isOn)
                .fixedSize()
            picker()
                .labelsHidden()
                .fixedSize()
                .controlSize(.regular)
                .disabled(!isOn.wrappedValue)
        }
    }

    /// Secondary explanatory line shown under an Applications toggle.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
