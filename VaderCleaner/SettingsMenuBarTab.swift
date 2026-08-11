// SettingsMenuBarTab.swift
// Menu Bar tab for the Settings window — which monitors appear in the menu bar panel.

import SwiftUI
import AppKit

// MARK: - Menu Bar tab

struct MenuBarTab: View {

    @Environment(PreferencesStore.self) private var preferences

    /// Cadences offered for the live readings, in seconds.
    private let intervalOptions: [Double] = [2, 5, 10]

    /// True when the menu bar icon is hidden, which makes everything about the
    /// icon and its panel moot.
    private var menuBarHidden: Bool { !preferences.showMenuBar }

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(
                symbol: "menubar.rectangle",
                title: "Menu Bar",
                subtitle: "Keep VaderCleaner and your Mac's vital signs within reach at the top of the screen."
            )
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, 6)

            Form {
                Section {
                    Picker("Keep VaderCleaner in", selection: $preferences.menuBarPresence) {
                        ForEach(MenuBarPresence.allCases) { presence in
                            Text(presence.label).tag(presence)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("preferences.menuBarPresence")
                } header: {
                    Text("Where to find it")
                } footer: {
                    Text("You'll always keep at least one way back into VaderCleaner, so this can't leave you with no icon at all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Show beside the icon", selection: $preferences.menuBarReading) {
                        ForEach(MenuBarReading.allCases) { reading in
                            Text(reading.label).tag(reading)
                        }
                    }
                    .accessibilityIdentifier("preferences.menuBarReading")
                } header: {
                    Text("The icon")
                } footer: {
                    Text("The icon on its own always fits. A reading beside it takes up room, and on a crowded menu bar it can end up hidden behind the notch — free space in particular barely changes between glances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(menuBarHidden)

                Section {
                    ForEach(MenuBarPanelRow.allCases) { row in
                        Toggle(row.label, isOn: Binding(
                            get: { preferences.isPanelRowEnabled(row) },
                            set: { preferences.setPanelRow(row, enabled: $0) }
                        ))
                        .accessibilityIdentifier("preferences.panelRow.\(row.rawValue)")
                    }
                } header: {
                    Text("In the panel")
                } footer: {
                    Text("Clicking the icon opens a panel with these rows. Hide the ones you don't need — Wi-Fi & network needs Location access to name your network, so it's worth turning off if you'd rather not grant that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.settingsCheckbox)
                .disabled(menuBarHidden)

                Section {
                    Picker("Refresh readings", selection: $preferences.statsUpdateInterval) {
                        ForEach(intervalOptions, id: \.self) { seconds in
                            Text("Every \(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("preferences.statsUpdateInterval")
                } header: {
                    Text("Live readings")
                } footer: {
                    Text("VaderCleaner only measures your Mac while the panel or the main window is open, so a faster refresh costs nothing while you're not looking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

#Preview {
    PreferencesView()
        .environment(PreferencesStore())
        .environment(ExclusionsStore())
        .environment(WebDevScanScopeStore())
        .environment(SmartScanSettingsStore())
        .environment(ProtectionSettingsStore())
        .environment(SettingsRouter())
        .environment(AppState())
        .environment(CareHistoryStore())
        .environment(
            NotificationSettingsModel(
                dispatcher: NotificationManager(authorizationRequester: { true }),
                permissionRequester: {}
            )
        )
        .environment(MyClutterScanScopeStore())
}
