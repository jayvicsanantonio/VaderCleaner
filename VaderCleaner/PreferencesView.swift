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
        // doesn't jump as the user switches tabs. The width accommodates the
        // Scanning tab's two-pane Smart Care layout; the form-based tabs simply
        // have more breathing room.
        .frame(width: 620, height: 460)
    }
}

// MARK: - Scanning tab (Customize Smart Care)

/// Lets the user choose which Smart Scan modules — and, within Cleanup, which
/// System Junk categories — a scan includes. Laid out as CleanMyMac's "Customize
/// Smart Care" screen: a left list (Smart Care / its Modules) selects what the
/// right pane shows, and the right pane is a hierarchical checkbox tree of
/// modules with glossy colored badge icons. The Cleanup parent carries a
/// disclosure triangle and a native tri-state checkbox over its category
/// children; disabling a module greys out and excludes its whole subtree.
private struct ScanningTab: View {

    /// Left-list selection: the whole Smart Care profile, or the Cleanup module
    /// drilled down to its own categories.
    private enum SidebarItem: Hashable { case smartCare, cleanup }

    @Environment(SmartScanSettingsStore.self) private var settings
    @State private var selection: SidebarItem = .smartCare
    @State private var cleanupExpanded = true

    /// Shared column widths so the disclosure triangles and checkboxes line up.
    private static let triangleWidth: CGFloat = 16
    private static let checkboxWidth: CGFloat = 18

    /// Every Smart Scan module except System Junk, which renders as the
    /// expandable Cleanup parent above its own category sub-tree.
    private static let standaloneModules: [SmartScanModule] =
        SmartScanModule.allCases.filter { $0 != .systemJunk }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Specify the items you would like to include to your scans:")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 14) {
                sidebar
                    .frame(width: 200)
                detail
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarRow(.smartCare, title: "Smart Care",
                       icon: ScanBadgeIcon(systemName: "display", tint: BadgePalette.pink))
            Text("Modules")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.leading, 8)
            sidebarRow(.cleanup, title: "Cleanup",
                       icon: ScanBadgeIcon(systemName: "sparkles", tint: BadgePalette.green))
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(paneBackground)
    }

    private func sidebarRow(_ item: SidebarItem, title: String, icon: ScanBadgeIcon) -> some View {
        let isSelected = selection == item
        return HStack(spacing: 10) {
            icon
            Text(title)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = item }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detailTitle)
                .font(.body)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    cleanupParentRow
                    if cleanupExpanded {
                        ForEach(SmartScanSettingsStore.junkCategories, id: \.self) { category in
                            categoryChildRow(category)
                        }
                    }
                    if selection == .smartCare {
                        ForEach(Self.standaloneModules, id: \.self) { module in
                            moduleRow(module)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(paneBackground)
    }

    private var detailTitle: String {
        selection == .cleanup ? "Categories to scan using Cleanup:" : "Modules to scan using Smart Care:"
    }

    // MARK: Rows

    /// The expandable Cleanup parent: triangle, tri-state checkbox, badge, label.
    private var cleanupParentRow: some View {
        HStack(spacing: 8) {
            disclosureTriangle
            NativeTriStateCheckbox(
                state: settings.junkCategoryState,
                identifier: "scanning.module.\(SmartScanModule.systemJunk.rawValue)",
                action: toggleCleanup
            )
            .frame(width: Self.checkboxWidth)
            ScanBadgeIcon(systemName: Self.symbol(.systemJunk), tint: Self.tint(.systemJunk))
            Text(Self.title(.systemJunk))
                .font(.system(size: 15))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    /// A System Junk category, indented one level under Cleanup. Greyed and
    /// non-interactive when the Cleanup module is off.
    private func categoryChildRow(_ category: ScanCategory) -> some View {
        let cleanupOn = settings.isModuleEnabled(.systemJunk)
        return HStack(spacing: 8) {
            leafCheckbox(
                isOn: settings.isJunkCategoryEnabled(category),
                identifier: "scanning.junkCategory.\(category.rawValue)"
            ) { settings.setJunkCategory(category, enabled: $0) }
            ScanBadgeIcon(systemName: Self.categorySymbol(category), tint: BadgePalette.green)
            Text(category.displayName)
                .font(.system(size: 15))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.leading, Self.triangleWidth + Self.checkboxWidth + 16)
        .padding(.trailing, 6)
        .disabled(!cleanupOn)
        .opacity(cleanupOn ? 1 : 0.45)
    }

    /// A module with no sub-tree: a triangle-width spacer keeps its checkbox in
    /// the same column as the Cleanup parent's.
    private func moduleRow(_ module: SmartScanModule) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Self.triangleWidth, height: 1)
            leafCheckbox(
                isOn: settings.isModuleEnabled(module),
                identifier: "scanning.module.\(module.rawValue)"
            ) { settings.setModule(module, enabled: $0) }
            ScanBadgeIcon(systemName: Self.symbol(module), tint: Self.tint(module))
            Text(Self.title(module))
                .font(.system(size: 15))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    // MARK: Building blocks

    private var disclosureTriangle: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { cleanupExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(cleanupExpanded ? 90 : 0))
                .frame(width: Self.triangleWidth, height: Self.triangleWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cleanupExpanded ? "Collapse Cleanup" : "Expand Cleanup")
    }

    /// A native macOS checkbox sized to the shared column — used for the leaf
    /// rows so they read as standard, fully-accessible controls.
    private func leafCheckbox(
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

    private var paneBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }

    // MARK: Actions

    /// The Cleanup checkbox primarily controls whether the module is included:
    /// clicking it while included (checked or mixed) excludes the whole subtree;
    /// clicking it while excluded includes the module and every category. The
    /// mixed dash signals that some categories are individually deselected.
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

    // MARK: Presentation

    private static func title(_ module: SmartScanModule) -> String {
        switch module {
        case .systemJunk: return "Cleanup"
        case .malware: return "Protection"
        case .optimization: return "Performance"
        case .applications: return "Applications"
        case .myClutter: return "My Clutter"
        }
    }

    private static func symbol(_ module: SmartScanModule) -> String {
        switch module {
        case .systemJunk: return "sparkles"
        case .malware: return "hand.raised.fill"
        case .optimization: return "bolt.fill"
        case .applications: return "square.grid.2x2.fill"
        case .myClutter: return "doc.on.doc.fill"
        }
    }

    private static func tint(_ module: SmartScanModule) -> Color {
        switch module {
        case .systemJunk: return BadgePalette.green
        case .malware: return BadgePalette.pink
        case .optimization: return BadgePalette.orange
        case .applications: return BadgePalette.blue
        case .myClutter: return BadgePalette.purple
        }
    }

    private static func categorySymbol(_ category: ScanCategory) -> String {
        switch category {
        case .systemCache: return "internaldrive.fill"
        case .userCache: return "externaldrive.fill"
        case .systemLogs: return "doc.text.fill"
        case .userLogs: return "doc.plaintext.fill"
        case .languageFiles: return "globe"
        case .mailAttachments: return "envelope.fill"
        case .iosBackups: return "iphone"
        case .trash: return "trash.fill"
        case .largeFile, .oldFile: return "doc.fill"
        }
    }
}

/// Glossy colored badge icon matching the Smart Care reference: a gradient-
/// filled circle with a soft top highlight and a white SF Symbol. Built in
/// SwiftUI so there are no image assets to maintain and the badges recolor with
/// the system appearance.
private struct ScanBadgeIcon: View {

    let systemName: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.92), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        .accessibilityHidden(true)
    }
}

/// The five Smart Care badge colors, tuned to the reference screenshot.
private enum BadgePalette {
    static let green = Color(red: 0.32, green: 0.76, blue: 0.36)
    static let pink = Color(red: 0.93, green: 0.32, blue: 0.56)
    static let orange = Color(red: 0.97, green: 0.55, blue: 0.16)
    static let blue = Color(red: 0.26, green: 0.56, blue: 0.95)
    static let purple = Color(red: 0.60, green: 0.42, blue: 0.90)
}

/// A truly native tri-state checkbox (`NSButton` with `allowsMixedState`) so the
/// Cleanup parent's checked / unchecked / mixed-dash states match macOS exactly,
/// the way `Toggle(.checkbox)` can't. The displayed state is always driven from
/// the model: a click fires `action`, which mutates the store, and the next
/// `updateNSView` reconciles the button's state.
private struct NativeTriStateCheckbox: NSViewRepresentable {

    let state: SmartScanSettingsStore.CheckState
    let identifier: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "",
                              target: context.coordinator,
                              action: #selector(Coordinator.didClick))
        button.allowsMixedState = true
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = Self.nsState(for: state)
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    private static func nsState(for state: SmartScanSettingsStore.CheckState) -> NSControl.StateValue {
        switch state {
        case .on: return .on
        case .off: return .off
        case .mixed: return .mixed
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func didClick() { action() }
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
