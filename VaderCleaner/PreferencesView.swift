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
/// System Junk categories — a scan includes. Laid out as CleanMyMac's "Customize
/// Smart Care" hierarchical checkbox tree: the Cleanup parent carries a
/// disclosure chevron and a tri-state checkbox over its System Junk category
/// children; disabling a module greys out and excludes its whole subtree. The
/// tree is hand-built (rather than `DisclosureGroup`) so the chevron, checkbox,
/// icon, and label sit in fixed, aligned columns.
private struct ScanningTab: View {

    @Environment(SmartScanSettingsStore.self) private var settings
    @State private var cleanupExpanded = true

    /// Width of the leading chevron column. Rows without a chevron reserve the
    /// same width so every checkbox lines up in one column.
    private static let chevronWidth: CGFloat = 18
    /// Width reserved for a checkbox so the custom (tri-state) and native (leaf)
    /// checkboxes share an alignment column.
    private static let checkboxWidth: CGFloat = 18

    /// Every Smart Scan module except System Junk, which renders as the
    /// expandable Cleanup parent above its own category sub-tree.
    private static let standaloneModules: [SmartScanModule] =
        SmartScanModule.allCases.filter { $0 != .systemJunk }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Specify the items you would like to include in your scans:")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    cleanupParentRow
                    if cleanupExpanded {
                        ForEach(SmartScanSettingsStore.junkCategories, id: \.self) { category in
                            categoryChildRow(category)
                        }
                    }
                    ForEach(Self.standaloneModules, id: \.self) { module in
                        moduleRow(module)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
        }
        .padding()
    }

    // MARK: Rows

    /// The expandable Cleanup parent: chevron, tri-state checkbox, icon, label.
    private var cleanupParentRow: some View {
        HStack(spacing: 6) {
            chevron
            CheckboxButton(state: settings.junkCategoryState, action: toggleCleanup)
                .frame(width: Self.checkboxWidth)
                .accessibilityIdentifier("scanning.module.\(SmartScanModule.systemJunk.rawValue)")
            moduleLabel(.systemJunk)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    /// A System Junk category, indented one level under Cleanup. Greyed and
    /// non-interactive when the Cleanup module is off.
    private func categoryChildRow(_ category: ScanCategory) -> some View {
        let cleanupOn = settings.isModuleEnabled(.systemJunk)
        return HStack(spacing: 6) {
            nativeCheckbox(
                isOn: settings.isJunkCategoryEnabled(category),
                identifier: "scanning.junkCategory.\(category.rawValue)"
            ) { settings.setJunkCategory(category, enabled: $0) }
            Text(category.displayName)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.leading, Self.chevronWidth + Self.checkboxWidth + 6)
        .padding(.trailing, 6)
        .disabled(!cleanupOn)
        .opacity(cleanupOn ? 1 : 0.45)
    }

    /// A module with no sub-tree: a chevron-width spacer keeps its checkbox in
    /// the same column as the Cleanup parent's.
    private func moduleRow(_ module: SmartScanModule) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.chevronWidth, height: 1)
            nativeCheckbox(
                isOn: settings.isModuleEnabled(module),
                identifier: "scanning.module.\(module.rawValue)"
            ) { settings.setModule(module, enabled: $0) }
            moduleLabel(module)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    // MARK: Building blocks

    private var chevron: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { cleanupExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(cleanupExpanded ? 90 : 0))
                .frame(width: Self.chevronWidth, height: Self.chevronWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cleanupExpanded ? "Collapse Cleanup" : "Expand Cleanup")
    }

    /// A native macOS checkbox sized to the shared column. Used for the leaf
    /// rows (modules without a sub-tree, and the categories) so they read as
    /// standard, fully-accessible controls.
    private func nativeCheckbox(
        isOn: Bool,
        identifier: String,
        set: @escaping (Bool) -> Void
    ) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.checkboxWidth, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func moduleLabel(_ module: SmartScanModule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(module))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(module))
                Text(Self.caption(module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    /// The Cleanup checkbox primarily controls whether the module is included:
    /// clicking it while included (checked or mixed) excludes the whole subtree;
    /// clicking it while excluded includes the module and every category. The
    /// mixed glyph signals that some categories are individually deselected.
    private func toggleCleanup() {
        if settings.isModuleEnabled(.systemJunk) {
            settings.setModule(.systemJunk, enabled: false)
        } else {
            settings.setModule(.systemJunk, enabled: true)
            for category in SmartScanSettingsStore.junkCategories {
                settings.setJunkCategory(category, enabled: true)
            }
        }
    }

    // MARK: Copy

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

/// The tri-state checkbox for the Cleanup parent: checked (all categories in),
/// unchecked (module excluded), or mixed (module in, some categories out).
/// Built on a plain `Button` with an SF Symbol because `Toggle` can't render a
/// mixed state; the symbols are tinted to read like the native macOS checkboxes
/// used by the leaf rows.
private struct CheckboxButton: View {

    let state: SmartScanSettingsStore.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(state == .off ? "0" : "1")
    }

    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
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
