// PreferencesView.swift
// SwiftUI Settings window — General, Scanning, Notifications, Menu, Protection, and Ignore List tabs bound to the preference and settings stores.

import SwiftUI
import AppKit

/// Root of the Settings scene. Splits the preference categories across a
/// `TabView` so the layout matches macOS's native Settings windows.
///
/// Each tab is a small, self-contained subview — they all read/write the same
/// `PreferencesStore` / `ExclusionsStore` environment objects, so users can
/// toggle anything in any order without orchestration. The actual side effects
/// (`SMAppService` registration, hiding the menu bar extra, sending
/// notifications) are wired in later prompts.
struct PreferencesView: View {

    @Environment(SettingsRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ScanningTab()
                .tabItem { Label("Scanning", systemImage: "desktopcomputer") }
                .tag(SettingsTab.scanning)

            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)

            MenuBarTab()
                .tabItem { Label("Menu", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menuBar)

            ProtectionTab()
                .tabItem { Label("Protection", systemImage: "hand.raised") }
                .tag(SettingsTab.protectionScan)

            ExclusionsTab()
                .tabItem { Label("Ignore List", systemImage: "nosign") }
                .tag(SettingsTab.exclusions)
        }
        // Fixed width so all tabs share the same window size and the window
        // doesn't jump as the user switches tabs. The width accommodates the
        // Scanning tab's two-pane Smart Care layout; the form-based tabs simply
        // have more breathing room.
        .frame(width: 620, height: 580)
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
    /// drilled down to its own sub-tree.
    private enum SidebarItem: Hashable { case smartCare, cleanup }

    @Environment(SmartScanSettingsStore.self) private var settings
    @State private var selection: SidebarItem = .smartCare
    /// Node ids whose children are revealed. Every module opens by default so the
    /// Smart Care tree shows each module's features on first view; the System Junk
    /// sub-group stays collapsed there and expands when Cleanup is selected.
    @State private var expanded: Set<String> = [
        "module.systemJunk", "module.malware", "module.performance",
        "module.applications", "module.myClutter",
    ]

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
        // System Junk shows collapsed in the Smart Care overview but expanded
        // when Cleanup is selected, so its categories are visible up front.
        .onChange(of: selection) { _, newValue in
            if newValue == .cleanup {
                expanded.insert("group.systemJunk")
            } else {
                expanded.remove("group.systemJunk")
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarRow(.smartCare, title: "Smart Care",
                       icon: ScanBadgeIcon(asset: "scanBadgeSmartCare"))
            Text("Modules")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.leading, 8)
            sidebarRow(.cleanup, title: "Cleanup",
                       icon: ScanBadgeIcon(asset: "scanBadgeCleanup"))
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
                    ForEach(rootNodes) { node in
                        ScanNodeRow(node: node, level: 0, expanded: $expanded)
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
        selection == .cleanup ? "Modules to scan using Cleanup:" : "Modules to scan using Smart Care:"
    }

    private var paneBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }

    // MARK: Tree model

    /// The top-level nodes shown in the detail pane. `.smartCare` shows every
    /// module; selecting Cleanup in the sidebar narrows to that module's own
    /// children (System Junk / Mail Attachments / Trash Bins), with no Cleanup
    /// parent row — matching the "Categories to scan using Cleanup:" view.
    private var rootNodes: [ScanNode] {
        switch selection {
        case .cleanup: return cleanupNode.children
        case .smartCare:
            return [cleanupNode,
                    moduleNode(.malware, features: [
                        ("Malware Removal", "scanBadgeMalware"),
                    ]),
                    moduleNode(.performance, features: [
                        ("Background Items", "scanBadgePerformance"),
                        ("Login Items", "scanBadgePerformance"),
                    ]),
                    moduleNode(.applications, features: [
                        ("Updater", "scanBadgeApplications"),
                    ]),
                    moduleNode(.myClutter, features: [
                        ("Duplicates", "scanBadgeMyClutter"),
                    ])]
        }
    }

    /// Cleanup → System Junk (further expandable) / Mail Attachments / Trash
    /// Bins, mirroring the reference's grouping of the System Junk categories.
    private var cleanupNode: ScanNode {
        ScanNode(
            id: "module.systemJunk",
            title: "Cleanup",
            badge: "scanBadgeCleanup",
            canMix: true,
            checkboxID: "scanning.module.systemJunk",
            state: { self.settings.junkCategoryState },
            toggle: self.toggleCleanup,
            isEnabled: { true },
            children: [
                systemJunkGroupNode,
                categoryNode(.mailAttachments, title: "Mail Attachments", badge: "scanBadgeMailAttachments"),
                categoryNode(.trash, title: "Trash Bins", badge: "scanBadgeTrash"),
            ]
        )
    }

    /// The named System Junk categories shown under Cleanup, matching the
    /// reference screenshot's set and order. Each title/badge is a display label
    /// over a real `ScanCategory` toggle.
    private static let systemJunkDisplays: [(category: ScanCategory, title: String, badge: String)] = [
        (.systemCache, "Broken Preferences", "scanBadgeSystemJunk"),
        (.userLogs, "User Log Files", "scanBadgeLogs"),
        (.documentVersions, "Document Versions", "scanBadgeDocumentVersions"),
        (.userCache, "User Cache Files", "scanBadgeUserCacheFiles"),
        (.xcodeJunk, "Xcode Junk", "scanBadgeXcodeJunk"),
    ]

    /// The "System Junk" sub-group: a tri-state over the named categories above.
    private var systemJunkGroupNode: ScanNode {
        let categories = Self.systemJunkDisplays.map(\.category)
        return ScanNode(
            id: "group.systemJunk",
            title: "System Junk",
            badge: "scanBadgeSystemJunk",
            canMix: true,
            checkboxID: "scanning.junkGroup.systemJunk",
            state: { self.groupState(categories) },
            toggle: { self.setCategories(categories, enabled: !self.allEnabled(categories)) },
            isEnabled: { self.settings.isModuleEnabled(.systemJunk) },
            children: Self.systemJunkDisplays.map { categoryNode($0.category, title: $0.title, badge: $0.badge) }
        )
    }

    private func categoryNode(_ category: ScanCategory, title: String, badge: String) -> ScanNode {
        ScanNode(
            id: "category.\(category.rawValue)",
            title: title,
            badge: badge,
            canMix: false,
            checkboxID: "scanning.junkCategory.\(category.rawValue)",
            state: { self.settings.isJunkCategoryEnabled(category) ? .on : .off },
            toggle: { self.settings.setJunkCategory(category, enabled: !self.settings.isJunkCategoryEnabled(category)) },
            isEnabled: { self.settings.isModuleEnabled(.systemJunk) }
        )
    }

    /// A non-Cleanup module rendered as a parent over its named features,
    /// matching the reference (Protection → Malware Removal, Performance →
    /// Background Items / Login Items, etc.). The parent and every child share
    /// the same toggle — the module's on/off state.
    private func moduleNode(_ module: SmartScanModule, features: [(title: String, badge: String)]) -> ScanNode {
        let toggle = { self.settings.setModule(module, enabled: !self.settings.isModuleEnabled(module)) }
        let state = { self.settings.isModuleEnabled(module) ? ScanState.on : .off }
        return ScanNode(
            id: "module.\(module.rawValue)",
            title: Self.title(module),
            badge: Self.badge(module),
            canMix: false,
            checkboxID: "scanning.module.\(module.rawValue)",
            state: state,
            toggle: toggle,
            isEnabled: { true },
            children: features.enumerated().map { index, feature in
                ScanNode(
                    id: "feature.\(module.rawValue).\(index)",
                    title: feature.title,
                    badge: feature.badge,
                    canMix: false,
                    checkboxID: "scanning.feature.\(module.rawValue).\(index)",
                    state: state,
                    toggle: toggle,
                    isEnabled: { true }
                )
            }
        )
    }

    // MARK: Derived state helpers

    private func allEnabled(_ categories: [ScanCategory]) -> Bool {
        categories.allSatisfy { settings.isJunkCategoryEnabled($0) }
    }

    private func groupState(_ categories: [ScanCategory]) -> ScanState {
        let on = categories.filter { settings.isJunkCategoryEnabled($0) }.count
        if on == 0 { return .off }
        if on == categories.count { return .on }
        return .mixed
    }

    private func setCategories(_ categories: [ScanCategory], enabled: Bool) {
        for category in categories {
            settings.setJunkCategory(category, enabled: enabled)
        }
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
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .myClutter: return "My Clutter"
        }
    }

    private static func badge(_ module: SmartScanModule) -> String {
        switch module {
        case .systemJunk: return "scanBadgeCleanup"
        case .malware: return "scanBadgeProtection"
        case .performance: return "scanBadgePerformance"
        case .applications: return "scanBadgeApplications"
        case .myClutter: return "scanBadgeMyClutter"
        }
    }

}

/// Tri-state of a checkbox in the Smart Care tree. Aliased to the store's
/// `CheckState` so the view and store share one vocabulary.
private typealias ScanState = SmartScanSettingsStore.CheckState

/// One node in the Smart Care tree. Carries closures (rather than a binding) so
/// a module, a category group, an individual category, and a module's single
/// named feature can all be expressed uniformly. The closures read/write the
/// store, so reading them inside a row body keeps SwiftUI observation intact.
private struct ScanNode: Identifiable {
    let id: String
    let title: String
    /// Asset-catalog name of the glossy badge artwork for this row.
    let badge: String
    /// Whether this node can show the mixed (dash) state — true for parents
    /// whose children can be partially selected, false for leaves.
    let canMix: Bool
    let checkboxID: String
    let state: () -> ScanState
    let toggle: () -> Void
    /// Whether the row is interactive; a category is disabled when its Cleanup
    /// module is off, so the whole subtree greys out.
    let isEnabled: () -> Bool
    var children: [ScanNode] = []
}

/// Renders a `ScanNode` and, when expanded, its children one indent level
/// deeper — a disclosure triangle (only when there are children), a native
/// checkbox, a glossy badge, and the title.
private struct ScanNodeRow: View {

    let node: ScanNode
    let level: Int
    @Binding var expanded: Set<String>

    private static let triangleWidth: CGFloat = 16
    private static let checkboxWidth: CGFloat = 18
    private static let indentStep: CGFloat = 26

    var body: some View {
        let isOpen = expanded.contains(node.id)
        let enabled = node.isEnabled()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                triangle(isOpen: isOpen)
                NativeTriStateCheckbox(
                    state: node.state(),
                    allowsMixed: node.canMix,
                    identifier: node.checkboxID,
                    action: node.toggle
                )
                .frame(width: Self.checkboxWidth)
                ScanBadgeIcon(asset: node.badge)
                Text(node.title)
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(level) * Self.indentStep)
            .padding(.trailing, 6)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)

            if isOpen {
                ForEach(node.children) { child in
                    ScanNodeRow(node: child, level: level + 1, expanded: $expanded)
                }
            }
        }
    }

    @ViewBuilder
    private func triangle(isOpen: Bool) -> some View {
        if node.children.isEmpty {
            Color.clear.frame(width: Self.triangleWidth, height: 1)
        } else {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if expanded.contains(node.id) { expanded.remove(node.id) }
                    else { expanded.insert(node.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: Self.triangleWidth, height: Self.triangleWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(isOpen ? "Collapse \(node.title)" : "Expand \(node.title)")
        }
    }
}

/// Glossy 3D Smart Care badge — a baked PNG orb (gradient body, specular
/// highlight, soft drop shadow) with a white emblem, in the MacPaw Smart Care
/// style. The artwork lives in the asset catalog (`scanBadge*`); its SVG sources
/// and the bake script are in `Scripts/ScanBadges`. The orb fills ~80% of the
/// frame (the rest is its baked shadow), so `size` is sized a little larger than
/// the visible orb.
private struct ScanBadgeIcon: View {

    let asset: String
    var size: CGFloat = 30

    var body: some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A truly native tri-state checkbox (`NSButton` with `allowsMixedState`) so the
/// Cleanup parent's checked / unchecked / mixed-dash states match macOS exactly,
/// the way `Toggle(.checkbox)` can't. The displayed state is always driven from
/// the model: a click fires `action`, which mutates the store, and the next
/// `updateNSView` reconciles the button's state.
private struct NativeTriStateCheckbox: NSViewRepresentable {

    let state: SmartScanSettingsStore.CheckState
    /// Whether this checkbox can display the mixed (dash) state. Leaf rows pass
    /// `false` so a click toggles cleanly off↔on instead of cycling through
    /// mixed.
    var allowsMixed: Bool = true
    let identifier: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "",
                              target: context.coordinator,
                              action: #selector(Coordinator.didClick))
        button.allowsMixedState = allowsMixed
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.allowsMixedState = allowsMixed
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

// MARK: - Protection tab

/// Scan options and scan-mode configuration for the Protection section,
/// mirroring the reference design. Bound to `ProtectionSettingsStore`; the
/// Malware view-model reads these at scan time so a change takes effect on the
/// next scan. The Configure Scan button on the Protection intro opens Settings
/// straight to this tab.
private struct ProtectionTab: View {

    @Environment(ProtectionSettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 0) {
            brandColumn
                .frame(width: 200)

            Divider()

            scanOptions
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
        }
    }

    // MARK: Brand column

    /// Left column: the app icon centered over the "POWERED by ClamAV"
    /// wordmark, matching the reference layout. The icon is the running app's
    /// own icon so it always reflects the shipped artwork.
    private var brandColumn: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("POWERED")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Text("by ClamAV")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Scan options

    private var scanOptions: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Scan options")
                    .font(.title2.weight(.semibold))

                Toggle("Scan email attachments", isOn: $settings.scanEmailAttachments)
                    .accessibilityIdentifier("protection.scanEmailAttachments")
                Toggle("Scan archives", isOn: $settings.scanArchives)
                    .accessibilityIdentifier("protection.scanArchives")
                HStack(spacing: 8) {
                    Toggle("Exclude downloaded iCloud files", isOn: $settings.excludeDownloadedICloudFiles)
                        .accessibilityIdentifier("protection.excludeDownloadedICloudFiles")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("Skips iCloud Drive files already downloaded to this Mac. Apple scans the canonical copies in iCloud, so excluding them speeds up scans.")
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.large)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("Scan mode:")
                    Picker("Scan mode:", selection: $settings.scanMode) {
                        ForEach(ScanMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("protection.scanMode")
                }

                VStack(alignment: .leading, spacing: 10) {
                    attribute("Speed", value: settings.scanMode.speed)
                    attribute("Depth", value: settings.scanMode.depth)
                    attribute("Purpose", value: settings.scanMode.purpose)
                }
            }
        }
    }

    /// One scan-mode attribute row: a bold label in a fixed leading column with
    /// the value wrapping beside it, as in the reference.
    private func attribute(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.body.weight(.semibold))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Notifications tab

private struct NotificationsTab: View {

    @Environment(PreferencesStore.self) private var preferences

    /// Picker option sets for the inline dropdowns.
    private let trashSizeOptions = [1, 2, 5, 10, 20]
    private let diskFreeOptions = [5, 10, 25, 50, 100, 200]

    var body: some View {
        @Bindable var preferences = preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("General") {
                    toggleRow("Remind to run regular Smart Care", isOn: $preferences.remindSmartCare) {
                        Picker("", selection: $preferences.smartCareFrequency) {
                            ForEach(SmartCareFrequency.allCases) { freq in
                                Text(freq.label).tag(freq)
                            }
                        }
                    }
                    toggleRow("Notify if Trash size exceeds", isOn: $preferences.notifyTrashSize) {
                        Picker("", selection: $preferences.trashSizeThresholdGB) {
                            ForEach(trashSizeOptions, id: \.self) { gb in
                                Text("\(gb) GB").tag(gb)
                            }
                        }
                    }
                    Toggle("Warn when connected device batteries are running low", isOn: $preferences.notifyDeviceBatteryLow)
                    Toggle("Notify when too low on free RAM", isOn: $preferences.notifyHighRAM)
                }

                section("Disk Space") {
                    toggleRow("Warn when free space is less than", isOn: $preferences.notifyLowDisk) {
                        Picker("", selection: $preferences.diskFreeThresholdGB) {
                            ForEach(diskFreeOptions, id: \.self) { gb in
                                Text("\(gb) GB").tag(gb)
                            }
                        }
                    }
                    Toggle("Notify when a drive is connected to the Mac", isOn: $preferences.notifyDriveConnected)
                    Toggle("Suggest to clean up overfilled external drives", isOn: $preferences.notifyOverfilledDrives)
                }

                section("Applications") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Offer to uninstall applications correctly", isOn: $preferences.offerUninstallOnTrash)
                        caption("If you put an application into Trash, you will be offered to uninstall it correctly.")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Notify about hung applications", isOn: $preferences.notifyHungApps)
                        caption("If any of your apps stop responding, use an easy way of force quitting them.")
                    }
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.large)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One category: a bold title in a fixed leading column with the category's
    /// toggle rows stacked beside it, matching the reference layout.
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.headline)
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) {
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

// MARK: - General tab

private struct GeneralTab: View {

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
        .environment(ProtectionSettingsStore())
        .environment(SettingsRouter())
}
