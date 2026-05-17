// PreferencesView.swift
// SwiftUI Settings window — Notifications, Exclusions, Startup, and Menu Bar tabs bound to PreferencesStore and ExclusionsStore.

import SwiftUI
import AppKit

/// Root of the Settings scene. Splits the four preference categories across a
/// `TabView` so the layout matches macOS's native Settings windows.
///
/// Each tab is a small, self-contained subview — they all read/write the same
/// `PreferencesStore` / `ExclusionsStore` environment objects, so users can
/// toggle anything in any order without orchestration. The actual side effects
/// (`SMAppService` registration, hiding the menu bar extra, sending
/// notifications) are wired in later prompts.
struct PreferencesView: View {

    var body: some View {
        TabView {
            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }

            ExclusionsTab()
                .tabItem { Label("Exclusions", systemImage: "minus.circle") }

            StartupTab()
                .tabItem { Label("Startup", systemImage: "power") }

            MenuBarTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        // Fixed width so all four tabs share the same window size and the
        // window doesn't jump as the user switches tabs.
        .frame(width: 460, height: 340)
    }
}

// MARK: - Notifications tab

private struct NotificationsTab: View {

    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        Form {
            Section("Alert me when") {
                Toggle("Disk space is running low", isOn: $preferences.notifyLowDisk)
                Toggle("RAM usage is high", isOn: $preferences.notifyHighRAM)
                Toggle("Malware is found", isOn: $preferences.notifyMalwareFound)
                Toggle("Large files are detected", isOn: $preferences.notifyLargeFilesFound)
            }

            Section("Disk space threshold") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: $preferences.diskSpaceThresholdPercent,
                        in: 1...50,
                        step: 1
                    ) {
                        Text("Disk space threshold")
                    } minimumValueLabel: {
                        Text("1%")
                    } maximumValueLabel: {
                        Text("50%")
                    }
                    Text("Notify when free space drops below \(Int(preferences.diskSpaceThresholdPercent))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!preferences.notifyLowDisk)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Exclusions tab

private struct ExclusionsTab: View {

    @EnvironmentObject private var exclusions: ExclusionsStore
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paths listed here will be skipped by every scanner.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(exclusions.exclusions, id: \.self) { path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .frame(minHeight: 160)
            .border(Color.secondary.opacity(0.2))

            HStack {
                Button {
                    presentAddPanel()
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add a file or folder to the exclusion list")

                Button {
                    if let selected = selection {
                        exclusions.remove(path: selected)
                        selection = nil
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                        .labelStyle(.iconOnly)
                }
                .disabled(selection == nil)
                .help("Remove the selected path")

                Spacer()
            }
        }
        .padding()
    }

    /// Presents an `NSOpenPanel` so the user can pick any file or folder.
    /// Whatever they pick gets added as an absolute path string — `ExclusionsStore`
    /// already dedupes so re-picking is harmless.
    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Choose a file or folder to exclude from scanning"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        exclusions.add(path: url.path)
    }
}

// MARK: - Startup tab

private struct StartupTab: View {

    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch VaderCleaner at login", isOn: $preferences.launchAtLogin)
            } footer: {
                Text("VaderCleaner will start automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu Bar tab

private struct MenuBarTab: View {

    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        Form {
            Section {
                Toggle("Show VaderCleaner in the menu bar", isOn: $preferences.showMenuBar)
                    .accessibilityIdentifier("preferences.showMenuBar")
            } footer: {
                Text("When disabled, the VaderCleaner icon and live stats are hidden from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    PreferencesView()
        .environmentObject(PreferencesStore())
        .environmentObject(ExclusionsStore())
}
