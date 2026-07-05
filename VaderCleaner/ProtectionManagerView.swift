// ProtectionManagerView.swift
// The Protection Manager — a white-card, CleanMyMac-style three-pane surface. The Privacy pane lists each browser's data categories with custom glossy icons, info popovers for non-removable categories, expandable per-item rows (cookies/downloads by domain), and per-item selection; the Malware Removal pane lists detected threats. Self-contained within the Protection section.

import SwiftUI

struct ProtectionManagerView: View {

    var malware: MalwareViewModel
    var privacyModel: ProtectionPrivacyModel
    var iconCache: AppIconCache
    let bundleURL: (Browser) -> URL?
    let onBack: () -> Void

    private enum Section: Hashable { case malware, privacy }

    private enum Sort: String, CaseIterable, Identifiable {
        case name, count
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name:  return String(localized: "Name", comment: "Protection Manager sort option.")
            case .count: return String(localized: "Count", comment: "Protection Manager sort option.")
            }
        }
    }

    @State private var section: Section = .privacy
    @State private var selectedBrowser: Browser?
    @State private var selectedThreats: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var infoCategory: ProtectionPrivacyCategory?
    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var confirming = false
    @State private var blockedBrowser: Browser?
    @State private var hasInitialized = false

    private static let accent = ManagerChrome.accent

    var body: some View {
        surface
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ManagerSurfaceChrome(accent: Self.accent))
            .accessibilityIdentifier("protection.manager")
            .task {
                if privacyModel.phase == .idle { await privacyModel.scan() }
                // Seed the right pane to the first browser whenever data is
                // already present — covers the pre-warmed case, where `browsers`
                // is populated before this view appears so `onChange` never fires.
                if selectedBrowser == nil { selectedBrowser = privacyModel.browsers.first }
                if !hasInitialized { hasInitialized = true; privacyModel.deselectAll() }
            }
            // Catches the case where a pre-warm scan is still in flight when the
            // manager opens: select the first browser the moment it lands.
            .onChange(of: privacyModel.browsers) { _, browsers in
                if selectedBrowser == nil { selectedBrowser = browsers.first }
            }
            .onChange(of: privacyModel.blockedByRunningBrowser) { _, b in if let b { blockedBrowser = b } }
            .alert(confirmTitle, isPresented: $confirming) {
                Button(String(localized: "Cancel", comment: "Cancel removal."), role: .cancel) {}
                Button(String(localized: "Remove", comment: "Confirm removal."), role: .destructive) { performRemove() }
            } message: {
                Text(String(localized: "The selected items will be permanently deleted. This cannot be undone.",
                            comment: "Protection Manager removal confirmation body."))
            }
            .alert(item: $blockedBrowser) { browser in
                Alert(
                    title: Text(String(localized: "Quit \(browser.displayName) first", comment: "Running-browser block title.")),
                    message: Text(String(localized: "These items are stored in a database \(browser.displayName) has open. Quit \(browser.displayName) and try again.", comment: "Running-browser block body.")),
                    dismissButton: .default(Text(String(localized: "OK", comment: "Acknowledge."))) {
                        privacyModel.acknowledgeBlock()
                    }
                )
            }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                sidebar.frame(width: 200)
                Divider().opacity(0.4)
                middlePane.frame(width: 300)
                Divider().opacity(0.4)
                rightPane.frame(maxWidth: .infinity)
            }
            Divider().opacity(0.4)
            footer
        }
    }

    /// The white light-mode card chrome shared with the other managers.
    private struct ManagerSurfaceChrome: ViewModifier {
        let accent: Color
        func body(content: Content) -> some View {
            content
                .environment(\.colorScheme, .light)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .padding(14)
                // Extend up under the title-bar safe area so the top margin is
                // as thin as the sides instead of leaving the toolbar's tall
                // gradient band above the card.
                .ignoresSafeArea(.container, edges: .top)
                .tint(accent)
                .environment(\.sectionAccent, accent)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(String(localized: "Back", comment: "Back button on the Protection Manager."))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("protection.manager.back")
            Spacer()
            Text(String(localized: "Protection Manager", comment: "Protection Manager screen title.")).font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search", comment: "Manager search placeholder."), text: $search)
                    .textFieldStyle(.plain).frame(width: 130)
                    .accessibilityIdentifier("protection.manager.search")
            }
            Menu {
                ForEach(Sort.allCases) { option in Button(option.label) { sort = option } }
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "Sort by:", comment: "Manager sort label.")).foregroundStyle(.secondary)
                    Text(sort.label).foregroundStyle(.tint)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("protection.manager.sort")
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 4) {
            NavRow(selected: section == .malware, action: { section = .malware }) {
                Text(String(localized: "Malware Removal", comment: "Protection Manager section."))
                    .font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("protection.manager.nav.malware")
            NavRow(selected: section == .privacy, action: { section = .privacy }) {
                Text(String(localized: "Privacy", comment: "Protection Manager section."))
                    .font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("protection.manager.nav.privacy")
            Spacer()
        }
        .padding(8)
    }

    // MARK: - Middle pane

    @ViewBuilder
    private var middlePane: some View {
        switch section {
        case .privacy:
            ScrollView {
                VStack(spacing: 6) {
                    PaneHeading(
                        title: String(localized: "Privacy", comment: "Privacy middle header."),
                        description: String(localized: "Instantly remove your browsing history, along with traces of your online and offline activities.", comment: "Privacy middle description."),
                        bottomPadding: 8
                    )
                    ForEach(privacyModel.browsers) { browser in browserRow(browser) }
                }
                .padding(12)
            }
        case .malware:
            ScrollView {
                VStack(spacing: 6) {
                    PaneHeading(
                        title: String(localized: "Malware Removal", comment: "Malware middle header."),
                        description: String(localized: "Threats detected during the scan.", comment: "Malware middle description."),
                        bottomPadding: 8
                    )
                    threatsSummaryRow
                }
                .padding(12)
            }
        }
    }

    private func browserRow(_ browser: Browser) -> some View {
        NavRow(selected: selectedBrowser == browser, action: { selectedBrowser = browser }) {
            HStack(spacing: 10) {
                browserIcon(browser)
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.displayName).font(.body.weight(.medium))
                    Text(managerItemsLabel(privacyModel.totalCount(browser))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var threatsSummaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "allergens").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Detected Threats", comment: "Threats row.")).font(.body.weight(.medium))
                Text(managerItemsLabel(threats.count)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        switch section {
        case .privacy:
            if let browser = selectedBrowser {
                PrivacyPane(
                    browser: browser,
                    model: privacyModel,
                    expanded: $expanded,
                    infoCategory: $infoCategory,
                    search: search,
                    sortByCount: sort == .count,
                    accent: Self.accent
                )
            } else {
                Color.clear
            }
        case .malware:
            // While the engine is still looking for threats, show the scanning
            // placeholder instead of an empty "No threats were found" list — the
            // results aren't in yet.
            if malware.isScanningPhase {
                MalwareScanningPlaceholder()
            } else {
                MalwareResultsPane(
                    threats: threats,
                    search: search,
                    selectedThreats: $selectedThreats,
                    accent: Self.accent
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Text(selectionSummary).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { confirming = true } label: {
                Text(String(localized: "Remove", comment: "Footer remove.")).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent).tint(Self.accent)
            .disabled(!canRemove)
            .accessibilityIdentifier("protection.manager.remove")
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: - Derived

    private var threats: [MalwareThreat] {
        if case .results(let found) = malware.phase { return found }
        return []
    }

    private var canRemove: Bool {
        switch section {
        case .privacy: return privacyModel.hasSelection
        case .malware: return !selectedThreats.isEmpty
        }
    }

    private var selectionSummary: String {
        switch section {
        case .privacy:
            let n = privacyModel.selectedCount
            return n == 0
                ? String(localized: "No Privacy Items Selected", comment: "Empty privacy selection.")
                : String(localized: "\(n) Privacy Items Selected", comment: "Privacy selection count.")
        case .malware:
            let n = selectedThreats.count
            return n == 0
                ? String(localized: "No Threats Selected", comment: "Empty threat selection.")
                : String(localized: "\(n) Threats Selected", comment: "Threat selection count.")
        }
    }

    private var confirmTitle: String {
        String(localized: "Remove selected items?", comment: "Removal confirmation title.")
    }

    private func performRemove() {
        switch section {
        case .privacy:
            Task { await privacyModel.remove() }
        case .malware:
            let selected = threats.filter { selectedThreats.contains($0.id) }
            Task { await malware.removeThreats(selected); onBack() }
        }
    }

    // MARK: - Icons

    @ViewBuilder
    private func browserIcon(_ browser: Browser) -> some View {
        if let url = bundleURL(browser) {
            Image(nsImage: iconCache.icon(for: url)).resizable().frame(width: 28, height: 28)
        } else {
            Image(systemName: "globe").font(.title3).foregroundStyle(.tint).frame(width: 28, height: 28)
        }
    }
}

// MARK: - Privacy pane

/// The right pane's Privacy content for one browser: a heading, a bulk
/// select/deselect menu, and each data category with its expandable per-item
/// rows. Owns the expand/collapse and info-popover state via bindings back to
/// the manager, and derives its own filtered/sorted item lists.
private struct PrivacyPane: View {

    let browser: Browser
    let model: ProtectionPrivacyModel
    @Binding var expanded: Set<String>
    @Binding var infoCategory: ProtectionPrivacyCategory?
    let search: String
    let sortByCount: Bool
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PaneHeading(
                    title: browser.displayName,
                    description: String(localized: "You may choose to remove all the locally stored items that remain after browser use.", comment: "Privacy pane description.")
                )
                ManagerSelectMenu(
                    any: model.hasSelection,
                    onAll: { model.setAllSelected(true, browser: browser) },
                    onNone: { model.setAllSelected(false, browser: browser) }
                )
                // Each category (with its expanded per-item rows) sits on its
                // own rounded glass card, matching the manager card rows used
                // across the app's other sections.
                VStack(spacing: 10) {
                    ForEach(ProtectionPrivacyCategory.allCases) { category in
                        VStack(spacing: 0) {
                            categoryRow(category)
                            if isExpanded(category) {
                                ForEach(sortedItems(category)) { item in
                                    itemRow(category, item)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .managerRowCard()
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
    }

    private func categoryRow(_ category: ProtectionPrivacyCategory) -> some View {
        HStack(spacing: 12) {
            leadingControl(category)
                .frame(width: 26)
            Image(category.iconAsset).resizable().interpolation(.high).scaledToFit().frame(width: 34, height: 34)
            Text(category.displayName).font(.body)
            Spacer(minLength: 8)
            Text(managerItemsLabel(model.count(browser, category))).font(.callout).foregroundStyle(.secondary)
            if category.isExpandable {
                Button { toggleExpanded(category) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        .rotationEffect(.degrees(isExpanded(category) ? 90 : 0))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 20, height: 1)
            }
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("protection.manager.category.\(browser.rawValue).\(category.rawValue)")
    }

    @ViewBuilder
    private func leadingControl(_ category: ProtectionPrivacyCategory) -> some View {
        switch category.kind {
        case .informational:
            Button { infoCategory = category } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { infoCategory == category }, set: { if !$0 { infoCategory = nil } })) {
                Text(category.info).font(.callout).padding(14).frame(width: 260)
            }
        case .removable:
            ManagerCheckbox(state: model.categoryState(browser, category), accent: accent) {
                model.toggleCategory(browser, category)
            }
        }
    }

    private func itemRow(_ category: ProtectionPrivacyCategory, _ item: PrivacyItem) -> some View {
        HStack(spacing: 12) {
            ManagerCheckbox(state: model.isItemSelected(browser, category, item.id) ? .on : .off, accent: accent) {
                model.toggleItem(browser, category, item.id)
            }
            .frame(width: 26)
            Text(item.label).font(.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(managerItemsLabel(item.count)).font(.callout).foregroundStyle(.secondary)
            Color.clear.frame(width: 20, height: 1)
        }
        .padding(.vertical, 7).padding(.leading, 34)
        .background(Color.primary.opacity(0.02))
    }

    private func sortedItems(_ category: ProtectionPrivacyCategory) -> [PrivacyItem] {
        let items = model.items(browser, category)
            .filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
        return sortByCount
            ? items.sorted { $0.count > $1.count }
            : items.sorted { $0.label < $1.label }
    }

    private func isExpanded(_ category: ProtectionPrivacyCategory) -> Bool {
        expanded.contains(key(category))
    }

    private func toggleExpanded(_ category: ProtectionPrivacyCategory) {
        let k = key(category)
        if expanded.contains(k) { expanded.remove(k) } else { expanded.insert(k) }
    }

    private func key(_ category: ProtectionPrivacyCategory) -> String {
        "\(browser.rawValue).\(category.rawValue)"
    }
}

// MARK: - Malware panes

/// The right pane's Malware content once the scan has settled: the detected
/// threats with per-file selection, or an empty-state line when the Mac is
/// clean. Derives its own filtered/sorted threat list.
private struct MalwareResultsPane: View {

    let threats: [MalwareThreat]
    let search: String
    @Binding var selectedThreats: Set<String>
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PaneHeading(
                    title: String(localized: "Detected Threats", comment: "Threats pane title."),
                    description: String(localized: "Select the infected files to remove. Removal is permanent.", comment: "Threats pane description.")
                )
                if threats.isEmpty {
                    Text(String(localized: "No threats were found.", comment: "Empty threats."))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } else {
                    ManagerSelectMenu(
                        any: !selectedThreats.isEmpty,
                        onAll: { selectedThreats = Set(threats.map(\.id)) },
                        onNone: { selectedThreats = [] }
                    )
                    VStack(spacing: 10) {
                        ForEach(sortedThreats) { threat in threatRow(threat) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
    }

    private func threatRow(_ threat: MalwareThreat) -> some View {
        HStack(spacing: 12) {
            ManagerCheckbox(state: selectedThreats.contains(threat.id) ? .on : .off, accent: accent) {
                if selectedThreats.contains(threat.id) { selectedThreats.remove(threat.id) }
                else { selectedThreats.insert(threat.id) }
            }
            .frame(width: 26)
            Image(systemName: "ant").font(.title3).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(threat.threatName).font(.body)
                Text(threat.filePath.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .managerRowCard()
    }

    private var sortedThreats: [MalwareThreat] {
        threats
            .filter { search.isEmpty || $0.threatName.localizedCaseInsensitiveContains(search) || $0.filePath.lastPathComponent.localizedCaseInsensitiveContains(search) }
            .sorted { $0.threatName < $1.threatName }
    }
}

/// Shown in the Malware Removal pane while the scan is still running — the app's
/// malware badge over a "Looking for threats…" message, attributed to the
/// ClamAV engine at the bottom.
private struct MalwareScanningPlaceholder: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image("scanBadgeMalware")
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 104, height: 104)
                Text(String(localized: "Looking for threats…",
                            comment: "Protection Manager malware pane title while scanning."))
                    .font(.title.weight(.semibold))
                Text(String(localized: "Scanning your Mac in the background. This may take a moment.",
                            comment: "Protection Manager malware pane subtitle while scanning."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Spacer()
            poweredByClamAV
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("protection.manager.malware.scanning")
    }

    private var poweredByClamAV: some View {
        HStack(spacing: 5) {
            Text(String(localized: "Powered by",
                        comment: "Attribution prefix before the malware engine name."))
                .foregroundStyle(.secondary)
            Text(verbatim: "ClamAV")
                .fontWeight(.semibold)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

/// Section heading (title + description) shared by the manager's panes. The
/// middle-pane headers pass a tighter bottom padding than the detail panes.
private struct PaneHeading: View {
    let title: String
    let description: String
    var bottomPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, bottomPadding)
    }
}

/// The "Select: Some/None" bulk menu shown above a pane's selectable rows.
private struct ManagerSelectMenu: View {
    let any: Bool
    let onAll: () -> Void
    let onNone: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "Select:", comment: "Bulk-select label.")).foregroundStyle(.secondary)
            Menu {
                Button(String(localized: "Select All", comment: "Select all.")) { onAll() }
                Button(String(localized: "Deselect All", comment: "Deselect all.")) { onNone() }
            } label: {
                Text(any ? String(localized: "Some", comment: "Some selected.") : String(localized: "None", comment: "None selected."))
                    .foregroundStyle(.tint)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("protection.manager.select")
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
    }
}

/// A tri-state checkbox tinted with the manager accent.
private struct ManagerCheckbox: View {
    let state: ProtectionPrivacyModel.CheckState
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Softened outline matching ManagerRowCheckbox's unchecked state.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accent.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                if state != .off {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(accent).frame(width: 18, height: 18)
                    Image(systemName: state == .mixed ? "minus" : "checkmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Localized "N items" label shared by the manager's rows.
private func managerItemsLabel(_ count: Int) -> String {
    String(localized: "\(count) items", comment: "Item count label.")
}
