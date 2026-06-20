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
            ScanningTab()
                .tabItem { Label("Scanning", systemImage: "magnifyingglass") }

            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }

            ExclusionsTab()
                .tabItem { Label("Exclusions", systemImage: "minus.circle") }

            StartupTab()
                .tabItem { Label("Startup", systemImage: "power") }

            MenuBarTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        // Fixed width so all tabs share the same window size and the window
        // doesn't jump as the user switches tabs. The height accommodates the
        // Scanning tab's module tree; the shorter tabs simply have more breathing
        // room.
        .frame(width: 480, height: 420)
    }
}

// MARK: - Scanning tab (Customize Smart Care)

/// Lets the user choose which Smart Scan modules — and, within Cleanup, which
/// System Junk categories — a scan includes. Laid out as a native grouped form
/// (matching the other preference tabs): a Modules section, then a Cleanup
/// Categories section that greys out when the Cleanup module is off, so a
/// disabled module visibly excludes its whole subtree.
private struct ScanningTab: View {

    @Environment(SmartScanSettingsStore.self) private var settings

    /// Every Smart Scan module, in dashboard reading order.
    private static let modules: [SmartScanModule] = SmartScanModule.allCases

    var body: some View {
        Form {
            Section {
                ForEach(Self.modules, id: \.self) { module in
                    moduleRow(module)
                }
            } header: {
                Text("Specify the items you would like to include in your scans")
            } footer: {
                Text("Smart Scan runs only the checked modules. Unchecked modules are skipped entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(SmartScanSettingsStore.junkCategories, id: \.self) { category in
                    categoryRow(category)
                }
            } header: {
                Text("Cleanup Categories")
            } footer: {
                Text(cleanupFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isModuleEnabled(.systemJunk))
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    private func moduleRow(_ module: SmartScanModule) -> some View {
        Toggle(isOn: Binding(
            get: { settings.isModuleEnabled(module) },
            set: { settings.setModule(module, enabled: $0) }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(module))
                    Text(Self.caption(module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: Self.symbol(module))
                    .foregroundStyle(.tint)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("scanning.module.\(module.rawValue)")
    }

    private func categoryRow(_ category: ScanCategory) -> some View {
        Toggle(category.displayName, isOn: Binding(
            get: { settings.isJunkCategoryEnabled(category) },
            set: { settings.setJunkCategory(category, enabled: $0) }
        ))
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("scanning.junkCategory.\(category.rawValue)")
    }

    // MARK: Copy

    /// Footer under the categories section, reflecting whether Cleanup is off,
    /// fully included, or partially narrowed.
    private var cleanupFooter: String {
        switch settings.junkCategoryState {
        case .off:
            return "Enable Cleanup above to scan system junk."
        case .mixed:
            return "Some system junk categories are excluded from Cleanup."
        case .on:
            return "Choose which kinds of system junk Cleanup scans."
        }
    }

    private static func title(_ module: SmartScanModule) -> String {
        switch module {
        case .systemJunk: return "Cleanup"
        case .malware: return "Protection"
        case .optimization: return "Performance"
        case .applications: return "Applications"
        case .myClutter: return "My Clutter"
        }
    }

    private static func caption(_ module: SmartScanModule) -> String {
        switch module {
        case .systemJunk: return "System junk: caches, logs, language files, and more"
        case .malware: return "Scan for malware and adware"
        case .optimization: return "Run system maintenance scripts"
        case .applications: return "Find available app updates"
        case .myClutter: return "Find large and old files"
        }
    }

    private static func symbol(_ module: SmartScanModule) -> String {
        switch module {
        case .systemJunk: return "trash"
        case .malware: return "shield.lefthalf.filled"
        case .optimization: return "bolt.fill"
        case .applications: return "app.badge"
        case .myClutter: return "doc.on.doc"
        }
    }
}

// MARK: - Notifications tab

private struct NotificationsTab: View {

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
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

    @Environment(ExclusionsStore.self) private var exclusions
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files and folders listed here are skipped by every scan.")
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
                .help("Add a file or folder to skip during scans")

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
                .help("Remove the selected item")

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

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
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

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Show VaderCleaner in the menu bar", isOn: $preferences.showMenuBar)
                    .accessibilityIdentifier("preferences.showMenuBar")
                Toggle("Show free space next to the icon", isOn: $preferences.menuBarShowsReading)
                    .accessibilityIdentifier("preferences.menuBarShowsReading")
                    .disabled(!preferences.showMenuBar)
            } footer: {
                Text("When disabled, the VaderCleaner icon and live stats are hidden from the menu bar. The free-space reading sits next to the icon — note a wide menu bar can hide it behind the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    PreferencesView()
        .environment(PreferencesStore())
        .environment(ExclusionsStore())
        .environment(SmartScanSettingsStore())
}
