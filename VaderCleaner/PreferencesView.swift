// PreferencesView.swift
// SwiftUI Settings window — General, Scanning, Notifications, Menu, Protection, and Ignore List tabs bound to the preference and settings stores.

import SwiftUI
import AppKit

/// Shared layout metrics so every tab's header and content line up on one grid
/// — the same left edge, top offset, and header-to-content gap across all six
/// panes, instead of each hardcoding its own padding.
private enum SettingsMetrics {
    /// Matches the grouped `Form`'s card inset so the custom panes' content and
    /// the Form tabs' headers share one left edge.
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 22
    static let bottomPadding: CGFloat = 22
    /// Gap between the pane header and the content below it.
    static let headerGap: CGFloat = 20
    /// Gap between stacked sections within a pane.
    static let sectionGap: CGFloat = 26
}

private extension Color {
    /// The Settings window's accent — the Smart Care section's violet, deepened
    /// and slightly desaturated so it reads rich rather than neon as a fill,
    /// tint, or selection highlight, and carries white glyphs and labels at a
    /// comfortable contrast (~5:1 vs the raw hue's ~3.8:1). The raw section
    /// accent stays too bright to sit under white as a solid background.
    static let settingsAccent = Color(red: 0.55, green: 0.30, blue: 0.85)
}

/// Root of the Settings scene. Splits the preference categories across a
/// `TabView` so the layout matches macOS's native Settings windows.
///
/// Each tab is a small, self-contained subview — they all read/write the same
/// `PreferencesStore` / `ExclusionsStore` environment objects, so users can
/// toggle anything in any order without orchestration. The whole window adopts
/// the Vader crimson as its control tint (checkboxes, switches, pickers,
/// selection) so the native macOS chrome still reads as part of the app.
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
        // The Smart Care violet carries through every SwiftUI control in the
        // window without fighting the system's Settings chrome.
        .tint(.settingsAccent)
        // Fixed size so all tabs share the same window and it doesn't jump as
        // the user switches tabs. The width accommodates the Scanning tab's
        // two-pane Smart Care layout. The height is sized for the content-rich
        // panes (Scanning, Notifications, Protection); those with more rows than
        // fit scroll inside their own `ScrollView`, so the sparse tabs (General,
        // Menu) don't have to carry a cavernous empty window.
        .frame(width: 620, height: 600)
    }
}

// MARK: - Shared chrome

/// A consistent pane header — a glossy circular icon beside a title and an
/// optional one-line description. Gives every tab the same branded anchor so the
/// window reads as one family rather than six unrelated forms.
private struct SettingsPaneHeader: View {

    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            SettingsBadgeIcon(symbol: symbol)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A glossy circular badge rendered at runtime: a top-lit violet orb with a
/// soft specular highlight, a fine rim, and a white SF Symbol — the Smart Care
/// look, sized for the settings pane headers. Rendering it in SwiftUI keeps the
/// six tab icons in one recolourable family with no baked assets to maintain.
private struct SettingsBadgeIcon: View {

    let symbol: String
    var tint: Color = .settingsAccent
    var diameter: CGFloat = 42

    var body: some View {
        let base = tint
        ZStack {
            // Body: a vertical gradient so the orb reads lit from above.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [base.opacity(1.0), base.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Specular highlight pooled near the top — a restrained glossy sheen.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 0.28),
                        startRadius: 0,
                        endRadius: diameter * 0.5
                    )
                )
                .blendMode(.screen)

            // A fine bright rim gives the orb a crisp edge on the dark backdrop.
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)

            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                // A faint shadow keeps the white glyph legible on the brighter
                // section tints (green, teal) as well as the deep ones.
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
        }
        .frame(width: diameter, height: diameter)
        // A tight, low shadow for a little lift — not the wide halo the baked
        // artwork carried. Scaled to the badge so small tree icons don't glow.
        .shadow(color: .black.opacity(0.22), radius: diameter * 0.05, y: 1)
        .accessibilityHidden(true)
    }
}

// MARK: - Scanning tab (Customize Smart Care)

/// Lets the user choose which Smart Scan modules — and, within Cleanup, which
/// System Junk categories — a scan includes. Laid out as CleanMyMac's "Customize
/// Smart Care" screen: a left list (Smart Care / its Modules) selects what the
/// right pane shows, and the right pane is a hierarchical tree of modules with
/// glossy colored badge icons. The Cleanup parent carries a disclosure triangle
/// and a native tri-state checkbox over its category children; disabling a
/// module greys out and excludes its whole subtree. A module's named features
/// are shown as read-only "what this covers" rows, since the scan engine
/// includes or excludes a module as a whole — only System Junk exposes
/// per-category control.
struct ScanningTab: View {

    @Environment(SmartScanSettingsStore.self) private var settings
    /// Node ids whose children are revealed. Every area — and Cleanup's System
    /// Junk sub-group — opens by default so the list shows its complete set of
    /// options on first view (System Caches, Xcode Junk, Web Development Junk, …).
    @State private var expanded: Set<String> = [
        "module.systemJunk", "group.systemJunk", "module.malware",
        "module.browserPrivacy", "module.performance", "module.applications",
        "module.myClutter",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
            SettingsPaneHeader(
                symbol: "desktopcomputer",
                title: "Scanning",
                subtitle: "Choose what every Smart Care scan looks through. Turn off anything you'd rather skip."
            )

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, SettingsMetrics.horizontalPadding)
        .padding(.top, SettingsMetrics.topPadding)
        .padding(.bottom, SettingsMetrics.bottomPadding)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Areas included in every scan")
                .font(.body.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rootNodes) { node in
                        ScanNodeRow(node: node, level: 0, expanded: $expanded)
                    }

                    // The Web Development Junk scan walks the user's own code
                    // folders, so it needs a folder choice the fixed-location
                    // categories don't. It surfaces only once the user opens
                    // System Junk, where Web Development Junk lives.
                    if expanded.contains("group.systemJunk") {
                        Divider()
                            .padding(.vertical, 8)
                        WebDevScanFolderPicker()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(paneBackground)
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

    /// One sub-scan row: the `CareScanUnit` it toggles, its label, and its icon.
    typealias UnitDisplay = (unit: CareScanUnit, title: String, symbol: String)

    /// The single source of truth for the non-Cleanup areas and the complete set
    /// of sub-scans each lists, in display order. `rootNodes` builds the tree
    /// from this, and `toggleableUnits` derives from it, so a domain can never
    /// gain a scan the settings quietly omit — the completeness test guards it.
    private static let moduleUnitDisplays: [(domain: CareDomain, units: [UnitDisplay])] = [
        (.malware, [(.malware, "Malware Removal", "ladybug.fill")]),
        (.browserPrivacy, [(.browserPrivacy, "Cookies & Browsing Traces", "circle.grid.cross.fill")]),
        (.performance, [
            (.loginItems, "Login Items", "arrow.right.circle.fill"),
            (.backgroundItems, "Background Items", "gearshape.2.fill"),
            (.maintenanceDue, "Maintenance Tasks", "wrench.and.screwdriver.fill"),
        ]),
        (.applications, [
            (.appUpdates, "App Updates", "arrow.down.circle.fill"),
            (.unusedApps, "Unused Apps", "app.dashed"),
            (.unsupportedApps, "Unsupported Apps", "exclamationmark.app"),
            (.extensions, "Extensions", "puzzlepiece.extension.fill"),
            (.appLeftovers, "App Leftovers", "shippingbox.fill"),
            (.installers, "Installers", "arrow.down.app.fill"),
        ]),
        (.myClutter, [
            (.duplicates, "Duplicates", "doc.on.doc.fill"),
            (.similarImages, "Similar Photos", "photo.on.rectangle.angled"),
            (.largeOldFiles, "Large & Old Files", "externaldrive.fill"),
            (.downloads, "Downloads", "arrow.down.circle.fill"),
        ]),
    ]

    /// Every sub-scan unit the tree exposes a toggle for — the direct unit rows
    /// plus the `systemJunk` unit that Cleanup covers through its category tree.
    /// A test asserts this equals every domain-bound `CareScanUnit`, so no scan
    /// can ship without a user-facing switch.
    static var toggleableUnits: Set<CareScanUnit> {
        Set(moduleUnitDisplays.flatMap { $0.units.map(\.unit) }).union([.systemJunk])
    }

    private static func units(for domain: CareDomain) -> [UnitDisplay] {
        moduleUnitDisplays.first { $0.domain == domain }?.units ?? []
    }

    /// Every scannable area, top to bottom. Each is a parent row over the real
    /// sub-scans (`CareScanUnit`s) it covers — each an independent checkbox so a
    /// user can scan, say, Duplicates but skip Large & Old Files. Browser Privacy
    /// nests under Protection since both guard the Mac; only Cleanup drills
    /// further, to its System Junk categories.
    private var rootNodes: [ScanNode] {
        var nodes: [ScanNode] = [cleanupNode]
        for (domain, units) in Self.moduleUnitDisplays where domain != .browserPrivacy {
            let extra: [ScanNode] = domain == .malware ? [browserPrivacyNode] : []
            nodes.append(moduleNode(domain, units: units, extraChildren: extra))
        }
        return nodes
    }

    /// Browser Privacy — its own scannable domain, shown as a sub-row under
    /// Protection with its own tri-state toggle, tinted to match the Protection
    /// group rather than its own hue.
    private var browserPrivacyNode: ScanNode {
        moduleNode(.browserPrivacy,
                   units: Self.units(for: .browserPrivacy),
                   tintOverride: CareDomain.malware.artTint)
    }

    /// Cleanup → System Junk (further expandable) / Mail Attachments / Trash
    /// Bins, mirroring the reference's grouping of the System Junk categories.
    private var cleanupNode: ScanNode {
        ScanNode(
            id: "module.systemJunk",
            title: "Cleanup",
            subtitle: Self.subtitle(.systemJunk),
            icon: .tinted(symbol: Self.symbol(.systemJunk), tint: Self.cleanupTint),
            canMix: true,
            checkboxID: "scanning.module.systemJunk",
            state: { self.settings.junkCategoryState },
            toggle: self.toggleCleanup,
            isEnabled: { true },
            children: [systemJunkGroupNode] + Self.cleanupLeafDisplays.map {
                categoryNode($0.category, title: $0.title, symbol: $0.symbol)
            }
        )
    }

    /// The Cleanup (green) tint every System Junk row wears, so the whole
    /// subtree matches the Cleanup module's section colour.
    private static let cleanupTint = CareDomain.systemJunk.artTint

    /// The category leaves shown directly under Cleanup, beside the System Junk
    /// sub-group — distinct user-data stores rather than named system-junk kinds.
    /// Each title/symbol is a display label over a real `ScanCategory` toggle.
    private static let cleanupLeafDisplays: [(category: ScanCategory, title: String, symbol: String)] = [
        (.mailAttachments, "Mail Attachments", "envelope.fill"),
        (.iosBackups, "iOS Backups", "iphone"),
        (.trash, "Trash Bins", "trash.fill"),
    ]

    /// Every System Junk `ScanCategory` the Cleanup tree renders a toggle for —
    /// the System Junk sub-group plus the Cleanup-level leaves. Exposed so a test
    /// can assert the tree covers every scannable junk category, guarding against
    /// a category that is scanned and filtered but has no user-facing toggle.
    static var toggleableJunkCategories: Set<ScanCategory> {
        Set(systemJunkDisplays.map(\.category))
            .union(cleanupLeafDisplays.map(\.category))
    }

    /// The named System Junk categories shown under Cleanup, matching the
    /// reference screenshot's set and order. Each title/symbol is a display label
    /// over a real `ScanCategory` toggle.
    private static let systemJunkDisplays: [(category: ScanCategory, title: String, symbol: String)] = [
        (.systemCache, "System Caches", "internaldrive.fill"),
        (.userLogs, "User Log Files", "doc.text.fill"),
        (.systemLogs, "System Log Files", "doc.text.fill"),
        (.documentVersions, "Document Versions", "clock.arrow.circlepath"),
        (.userCache, "User Cache Files", "externaldrive.fill"),
        (.languageFiles, "Language Files", "globe"),
        (.xcodeJunk, "Xcode Junk", "hammer.fill"),
        (.webDevJunk, "Web Development Junk", "chevron.left.forwardslash.chevron.right"),
    ]

    /// The "System Junk" sub-group: a tri-state over the named categories above.
    private var systemJunkGroupNode: ScanNode {
        let categories = Self.systemJunkDisplays.map(\.category)
        return ScanNode(
            id: "group.systemJunk",
            title: "System Junk",
            icon: .tinted(symbol: "xmark.bin.fill", tint: Self.cleanupTint),
            canMix: true,
            checkboxID: "scanning.junkGroup.systemJunk",
            state: { self.groupState(categories) },
            toggle: { self.setCategories(categories, enabled: !self.allEnabled(categories)) },
            isEnabled: { self.settings.isDomainEnabled(.systemJunk) },
            children: Self.systemJunkDisplays.map { categoryNode($0.category, title: $0.title, symbol: $0.symbol) }
        )
    }

    private func categoryNode(_ category: ScanCategory, title: String, symbol: String) -> ScanNode {
        ScanNode(
            id: "category.\(category.rawValue)",
            title: title,
            icon: .tinted(symbol: symbol, tint: Self.cleanupTint),
            canMix: false,
            checkboxID: "scanning.junkCategory.\(category.rawValue)",
            state: { self.settings.isJunkCategoryEnabled(category) ? .on : .off },
            toggle: { self.settings.setJunkCategory(category, enabled: !self.settings.isJunkCategoryEnabled(category)) },
            isEnabled: { self.settings.isDomainEnabled(.systemJunk) }
        )
    }

    /// A non-Cleanup module rendered as a tri-state parent over its real
    /// sub-scans. Each unit child is an independent checkbox, so a user can keep
    /// a module on while skipping one of its scans; the parent shows the dash
    /// when only some are on. The children grey out when the module is off — the
    /// scan configuration ANDs domain and unit. `extraChildren` lets a module
    /// host a nested sub-module (Protection hosts Browser Privacy);
    /// `tintOverride` lets that guest borrow the host's colour.
    private func moduleNode(
        _ module: CareDomain,
        units: [(unit: CareScanUnit, title: String, symbol: String)],
        extraChildren: [ScanNode] = [],
        tintOverride: Color? = nil
    ) -> ScanNode {
        let tint = tintOverride ?? module.artTint
        return ScanNode(
            id: "module.\(module.rawValue)",
            title: Self.title(module),
            subtitle: Self.subtitle(module),
            icon: .tinted(symbol: Self.symbol(module), tint: tint),
            canMix: true,
            checkboxID: "scanning.module.\(module.rawValue)",
            state: { self.settings.unitState(for: module) },
            toggle: { self.toggleModule(module) },
            isEnabled: { true },
            children: units.map { u in
                ScanNode(
                    id: "unit.\(u.unit.rawValue)",
                    title: u.title,
                    icon: .tinted(symbol: u.symbol, tint: tint),
                    canMix: false,
                    checkboxID: "scanning.unit.\(u.unit.rawValue)",
                    state: { self.settings.isUnitEnabled(u.unit) ? .on : .off },
                    toggle: { self.settings.setUnit(u.unit, enabled: !self.settings.isUnitEnabled(u.unit)) },
                    isEnabled: { self.settings.isDomainEnabled(module) }
                )
            } + extraChildren
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
        if settings.isDomainEnabled(.systemJunk) {
            settings.setDomain(.systemJunk, enabled: false)
        } else {
            settings.setDomain(.systemJunk, enabled: true)
            for category in SmartScanSettingsStore.junkCategories {
                settings.setJunkCategory(category, enabled: true)
            }
        }
    }

    /// A module's parent checkbox, driven by the visible tri-state: clicking it
    /// while anything is on (checked or dashed) excludes the whole area; clicking
    /// it while fully off — whether the domain is off or every unit was
    /// individually deselected — re-includes the module and all its sub-scans.
    private func toggleModule(_ module: CareDomain) {
        if settings.unitState(for: module) == .off {
            settings.setDomain(module, enabled: true)
            for unit in module.units {
                settings.setUnit(unit, enabled: true)
            }
        } else {
            settings.setDomain(module, enabled: false)
        }
    }

    // MARK: Presentation

    private static func title(_ module: CareDomain) -> String {
        switch module {
        case .systemJunk: return "Cleanup"
        case .malware: return "Protection"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .myClutter: return "My Clutter"
        case .browserPrivacy: return "Browser Privacy"
        }
    }

    /// Plain-language, jargon-free description of what each area scans, shown
    /// under the title so a non-technical user knows what turning it off skips.
    private static func subtitle(_ module: CareDomain) -> String {
        switch module {
        case .systemJunk: return "Remove junk files, caches, and trash"
        case .malware: return "Scan for malware and online threats"
        case .performance: return "Manage background items and maintenance"
        case .applications: return "Find updates, unused apps, and leftovers"
        case .myClutter: return "Find duplicate, large, and old files"
        case .browserPrivacy: return "Clear cookies and browsing traces"
        }
    }

    /// The area's own SF Symbol, drawn on a badge tinted with its section colour.
    private static func symbol(_ module: CareDomain) -> String {
        switch module {
        case .systemJunk: return "sparkles"
        case .malware: return "hand.raised.fill"
        case .performance: return "bolt.fill"
        case .applications: return "square.grid.2x2.fill"
        case .myClutter: return "square.stack.3d.up.fill"
        case .browserPrivacy: return "hand.raised.slash.fill"
        }
    }

}

/// Tri-state of a checkbox in the Smart Care tree. Aliased to the store's
/// `CheckState` so the view and store share one vocabulary.
private typealias ScanState = SmartScanSettingsStore.CheckState

/// A tree row's icon: a top-level module wears its section's baked 3D art;
/// every sub-row wears a glossy badge tinted with that same section's colour,
/// so a subtree reads as one hue.
private enum ScanNodeIcon {
    case art(String)
    case tinted(symbol: String, tint: Color)
}

/// One node in the Smart Care tree. Carries closures (rather than a binding) so
/// a module, a category group, an individual category, and a module's single
/// named feature can all be expressed uniformly. The closures read/write the
/// store, so reading them inside a row body keeps SwiftUI observation intact.
private struct ScanNode: Identifiable {
    let id: String
    let title: String
    /// A plain-language description shown under the title on top-level areas, so
    /// a non-technical user understands what the area scans. Leaves omit it.
    var subtitle: String? = nil
    /// The row's icon — either a module's baked section artwork or a symbol
    /// tinted with its parent section's colour.
    let icon: ScanNodeIcon
    /// Whether this node can show the mixed (dash) state — true for parents
    /// whose children can be partially selected, false for leaves.
    let canMix: Bool
    let checkboxID: String
    let state: () -> ScanState
    let toggle: () -> Void
    /// Whether the row is interactive; a category is disabled when its Cleanup
    /// module is off, so the whole subtree greys out.
    let isEnabled: () -> Bool
    /// A descriptive row carries no checkbox — it names one thing the module
    /// covers rather than offering an independent toggle.
    var isDescriptive: Bool = false
    var children: [ScanNode] = []
}

/// Renders a `ScanNode` and, when expanded, its children one indent level
/// deeper — a disclosure triangle (only when there are children), a native
/// checkbox (or, for descriptive rows, a placeholder), a glossy badge, and the
/// title.
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
                checkbox
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .font(.system(size: 15))
                        .foregroundStyle(node.isDescriptive ? Color.secondary : Color.primary)
                    if let subtitle = node.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, node.subtitle == nil ? 6 : 8)
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

    /// A module wears its baked section art; every sub-row wears a glossy badge
    /// tinted with the module's colour, so the subtree reads as one hue.
    @ViewBuilder
    private var icon: some View {
        switch node.icon {
        case .art(let asset):
            ScanBadgeIcon(asset: asset)
        case .tinted(let symbol, let tint):
            SettingsBadgeIcon(symbol: symbol, tint: tint, diameter: 26)
        }
    }

    /// Interactive rows get the rounded Smart Care checkbox; descriptive rows
    /// keep the same leading gutter width so their badge and title line up under
    /// the module, without a control the user can click.
    @ViewBuilder
    private var checkbox: some View {
        if node.isDescriptive {
            Color.clear.frame(width: Self.checkboxWidth, height: 1)
        } else {
            SettingsTreeCheckbox(
                state: node.state(),
                identifier: node.checkboxID,
                action: node.toggle
            )
            .frame(width: Self.checkboxWidth)
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

/// The rounded Smart Care checkbox, matching the manager row cards
/// (`ManagerRowCheckbox`): an accent-filled rounded square with a white check
/// when on, a white dash when mixed, and a soft accent outline when off. Purely
/// visual — the wrappers below add the tap target, model wiring, and
/// accessibility so the same glyph serves both the Scanning tree and the
/// checkbox toggles.
private struct SettingsCheckboxGlyph: View {

    let state: SmartScanSettingsStore.CheckState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let side: CGFloat = 18
    private static let corner: CGFloat = 5

    var body: some View {
        ZStack {
            switch state {
            case .on:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Color.settingsAccent)
                glyph("checkmark")
            case .mixed:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Color.settingsAccent)
                glyph("minus")
            case .off:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(Color.settingsAccent.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .animation(VaderMotion.control, value: state)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            // The mark pops in from a smaller scale with the control spring, so
            // ticking a box answers with a little bounce; Reduce Motion fades.
            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
    }
}

/// A tappable tri-state checkbox for the Scanning tree. Reports its on/off state
/// through accessibility so the identifier-based UI tests still read a value.
private struct SettingsTreeCheckbox: View {

    let state: SmartScanSettingsStore.CheckState
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsCheckboxGlyph(state: state)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(state == .off ? "0" : "1")
        .accessibilityAddTraits(state == .off ? [] : .isSelected)
    }
}

/// Renders SwiftUI `Toggle`s in the Notifications and Protection panes with the
/// same rounded Smart Care checkbox, so every checkbox in Settings matches the
/// manager rows. The whole row is the tap target.
private struct SettingsCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                SettingsCheckboxGlyph(state: configuration.isOn ? .on : .off)
                configuration.label
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == SettingsCheckboxToggleStyle {
    /// The rounded Smart Care checkbox toggle style used across Settings.
    static var settingsCheckbox: SettingsCheckboxToggleStyle { SettingsCheckboxToggleStyle() }
}

// MARK: - Protection tab

/// Scan options and scan-mode configuration for the Protection section. Bound to
/// `ProtectionSettingsStore`; the Malware view-model reads these at scan time so
/// a change takes effect on the next scan. The Configure Scan button on the
/// Protection intro opens Settings straight to this tab.
///
/// Single-column, on the shared settings grid: content-type checkboxes, then a
/// stack of selectable scan-mode cards — one per `ScanMode` — each showing its
/// speed, depth, and purpose, with the active mode highlighted in the accent.
private struct ProtectionTab: View {

    @Environment(ProtectionSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
                SettingsPaneHeader(
                    symbol: "hand.raised",
                    title: "Protection",
                    subtitle: "How the malware scan inspects your Mac."
                )

                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                    scanOptionsSection

                    scanModeSection
                }
            }
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, SettingsMetrics.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Scan options

    private var scanOptionsSection: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("Scan options")
                .font(.headline)

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
        .toggleStyle(.settingsCheckbox)
    }

    // MARK: Scan mode

    private var scanModeSection: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("Scan mode")
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(ScanMode.allCases) { mode in
                    ScanModeCard(
                        mode: mode,
                        isSelected: settings.scanMode == mode
                    ) {
                        settings.scanMode = mode
                    }
                    .accessibilityIdentifier("protection.scanMode.\(mode.rawValue)")
                }
            }
        }
    }
}

/// One selectable scan-mode option: a radio indicator, the mode's name with its
/// speed and depth as chips, and its purpose. The active card fills and outlines
/// in the settings accent. Tapping anywhere on the card selects the mode.
private struct ScanModeCard: View {

    let mode: ScanMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                radio
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(mode.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        chip(mode.speed)
                        chip(mode.depth)
                    }
                    Text(mode.purpose)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected
                          ? Color.settingsAccent.opacity(0.14)
                          : Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.settingsAccent.opacity(0.85) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(VaderMotion.control, value: isSelected)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var radio: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? Color.settingsAccent : Color.secondary.opacity(0.5),
                    lineWidth: 1.5
                )
            if isSelected {
                Circle()
                    .fill(Color.settingsAccent)
                    .padding(4)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .fixedSize()
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
            VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
                SettingsPaneHeader(
                    symbol: "bell",
                    title: "Notifications",
                    subtitle: "Pick which alerts VaderCleaner may send you."
                )

                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                section("General") {
                    toggleRow("Remind to run regular Smart Care", isOn: $preferences.remindSmartCare) {
                        Picker("", selection: $preferences.smartCareFrequency) {
                            ForEach(SmartCareFrequency.allCases) { freq in
                                Text(freq.label).tag(freq)
                            }
                        }
                    }
                    Toggle("Notify when a scan finishes", isOn: $preferences.notifyScanFinished)
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

                section("Scan Results") {
                    Toggle("Notify when malware is found", isOn: $preferences.notifyMalwareFound)
                    Toggle("Notify when large files are found", isOn: $preferences.notifyLargeFilesFound)
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
            }
            .toggleStyle(.settingsCheckbox)
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, SettingsMetrics.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

// MARK: - Exclusions tab

private struct ExclusionsTab: View {

    @Environment(ExclusionsStore.self) private var exclusions
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
            SettingsPaneHeader(
                symbol: "nosign",
                title: "Ignore List",
                subtitle: "Files and folders listed here are skipped by every scan."
            )

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )

                if exclusions.exclusions.isEmpty {
                    emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(exclusions.exclusions, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            }
                            .tag(path)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button {
                    presentAddPanel()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a file or folder to skip during scans")

                Button(role: .destructive) {
                    if let selected = selection {
                        exclusions.remove(path: selected)
                        selection = nil
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected item")

                Spacer()

                if !exclusions.exclusions.isEmpty {
                    let count = exclusions.exclusions.count
                    Text(count == 1 ? "1 item" : "\(count) items")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.horizontalPadding)
        .padding(.top, SettingsMetrics.topPadding)
        .padding(.bottom, SettingsMetrics.bottomPadding)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "nosign")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Nothing is being ignored")
                .font(.headline)
            Text("Use the + button to skip a file or folder during every scan.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
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
    @Environment(ProtectionSettingsStore.self) private var protectionSettings
    @Environment(SmartScanSettingsStore.self) private var smartScanSettings

    @State private var isConfirmingRestore = false

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
                subtitle: "App information and startup options."
            )
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, 6)

            Form {
                Section {
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
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle("Launch VaderCleaner at login", isOn: $preferences.launchAtLogin)
                } header: {
                    Text("Startup")
                } footer: {
                    Text("VaderCleaner will start automatically when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingRestore = true
                    } label: {
                        Label("Restore Defaults…", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Resets scanning, protection, notification, menu bar, and startup settings to their defaults. Your Ignore List is kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
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
            Text("This can't be undone. Your Ignore List of skipped files and folders is left unchanged.")
        }
    }
}

// MARK: - Menu Bar tab

private struct MenuBarTab: View {

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(
                symbol: "menubar.rectangle",
                title: "Menu",
                subtitle: "Show VaderCleaner and its live stats in the menu bar."
            )
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, 6)

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
}

#Preview {
    PreferencesView()
        .environment(PreferencesStore())
        .environment(ExclusionsStore())
        .environment(WebDevScanScopeStore())
        .environment(SmartScanSettingsStore())
        .environment(ProtectionSettingsStore())
        .environment(SettingsRouter())
}
