// SettingsScanningTab.swift
// Scanning tab for the Settings window — the per-unit scan tree choosing which Smart Scan modules and junk categories run.

import SwiftUI
import AppKit

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
    @Environment(WebDevScanScopeStore.self) private var webDevScope
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
                subtitle: "Smart Scan looks through everything ticked below. Turn off anything you'd rather it left alone."
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
    /// Order follows the app's navigation rail (`NavigationSection.allCases`):
    /// Cleanup → My Clutter → Protection → Performance → Applications, so the
    /// settings read in the same sequence as the sidebar. Cleanup leads the tree
    /// from `rootNodes`; Browser Privacy is listed here for its units but renders
    /// nested under Protection.
    private static let moduleUnitDisplays: [(domain: CareDomain, units: [UnitDisplay])] = [
        (.myClutter, [
            (.duplicates, "Duplicates", "doc.on.doc.fill"),
            (.similarImages, "Similar Photos", "photo.on.rectangle.angled"),
            (.largeOldFiles, "Large & Old Files", "externaldrive.fill"),
            (.downloads, "Downloads", "arrow.down.circle.fill"),
        ]),
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
            (.unsupportedApps, "Unsupported Apps", "xmark.app.fill"),
            (.extensions, "Extensions", "puzzlepiece.extension.fill"),
            (.appLeftovers, "App Leftovers", "shippingbox.fill"),
            (.installers, "Installers", "arrow.down.app.fill"),
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
            children: visibleSystemJunkDisplays.map {
                categoryNode($0.category, title: $0.title, symbol: $0.symbol)
            }
        )
    }

    /// The System Junk categories worth showing. Web Development Junk drops out
    /// when there are no coding-project folders on this Mac and none has been
    /// picked — the scan would find nothing, and asking someone who doesn't
    /// write code where their "project junk" lives is pure confusion. The full
    /// `systemJunkDisplays` list still backs `toggleableJunkCategories`, so the
    /// category stays scannable and its completeness test unaffected.
    private var visibleSystemJunkDisplays: [(category: ScanCategory, title: String, symbol: String)] {
        Self.systemJunkDisplays.filter { $0.category != .webDevJunk || !webDevScope.isDormant }
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
            isEnabled: { self.settings.isDomainEnabled(.systemJunk) },
            // The folder choice belongs to Web Development Junk, so it renders
            // directly beneath that row — not stranded at the bottom of the
            // list, forty rows from the checkbox it configures.
            accessory: category == .webDevJunk ? .webDevScanFolder : nil
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
            // My Clutter's scan folder is a durable preference, so it belongs
            // beside the scan it configures — the same treatment Web
            // Development Junk gets. The intro screen's picker remains the
            // fast path; both write the same store.
            accessory: module == .myClutter ? .myClutterScanFolder : nil,
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
        case .systemJunk: return "Temporary files your Mac doesn't need"
        case .malware: return "Malware and other threats"
        case .performance: return "What starts up and runs in the background"
        case .applications: return "Updates, apps you never open, and leftovers"
        case .myClutter: return "Duplicates, large files, and old downloads"
        case .browserPrivacy: return "Cookies and traces of where you've been"
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

/// An extra control a row carries beneath itself. Modelled as a marker rather
/// than an erased view so `ScanNode` stays a plain data description of the tree.
private enum ScanNodeAccessory {
    /// The Web Development Junk folder chooser.
    case webDevScanFolder
    /// The My Clutter scan-folder chooser. The same store backs the picker on
    /// the My Clutter intro, so the two stay in sync without extra wiring.
    case myClutterScanFolder
}

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
    /// An extra control rendered beneath the row, shown only while the row is
    /// both enabled and ticked.
    var accessory: ScanNodeAccessory? = nil
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

            // Only while the row is on: a folder choice for a scan the user has
            // switched off is a decision about nothing.
            if let accessory = node.accessory, enabled, node.state() != .off {
                accessoryView(accessory)
                    .padding(.leading, CGFloat(level + 1) * Self.indentStep)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            }

            if isOpen {
                ForEach(node.children) { child in
                    ScanNodeRow(node: child, level: level + 1, expanded: $expanded)
                }
            }
        }
    }

    @ViewBuilder
    private func accessoryView(_ accessory: ScanNodeAccessory) -> some View {
        switch accessory {
        case .webDevScanFolder:
            WebDevScanFolderPicker()
        case .myClutterScanFolder:
            MyClutterFolderPicker(accent: .settingsAccent, style: .settings)
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
                    if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
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
