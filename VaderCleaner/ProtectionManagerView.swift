// ProtectionManagerView.swift
// The Protection Manager — a white-card, CleanMyMac-style three-pane surface. The Privacy pane lists each browser's data categories with custom glossy icons, info popovers for non-removable categories, expandable per-item rows (cookies/downloads by domain), and per-item selection; the Malware Removal pane lists detected threats. Self-contained within the Protection section.

import SwiftUI
import VaderCleanerCore

/// Where a dashboard button opens the manager.
enum ProtectionManagerFocus: Equatable {
    /// The Privacy pane, on whichever browser was last showing.
    case privacy
    case browser(Browser)
}

struct ProtectionManagerView: View {

    var malware: MalwareViewModel
    var privacyModel: ProtectionPrivacyModel
    var iconCache: AppIconCache
    let bundleURL: (Browser) -> URL?
    /// Where to open, consumed as soon as it's been shown.
    @Binding var focus: ProtectionManagerFocus?
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
                applyFocus()
            }
            .onChange(of: focus) { _, _ in applyFocus() }
            // Catches the case where a pre-warm scan is still in flight when the
            // manager opens: select the first browser the moment it lands.
            .onChange(of: privacyModel.browsers) { _, browsers in
                if selectedBrowser == nil { selectedBrowser = browsers.first }
            }
            // A search belongs to the pane it was typed in.
            .onChange(of: section) { _, _ in search = "" }
            // Keep a browser on screen that the search can actually show.
            .onChange(of: search) { _, query in
                guard let selectedBrowser, !privacyModel.browserMatches(selectedBrowser, search: query) else { return }
                self.selectedBrowser = browserRows.first ?? selectedBrowser
            }
            // A selection only ever stands for threats still listed. During a
            // removal it's left alone, so anything that fails stays ticked.
            .onChange(of: malware.threatListState) { _, state in
                switch state {
                case .threats(let listed):
                    selectedThreats.formIntersection(listed.map(\.id))
                case .removing:
                    break
                case .scanning, .clean, .removed, .notScanned, .failed, .engineMissing:
                    selectedThreats = []
                }
            }
            .alert(confirmTitle, isPresented: $confirming) {
                Button(String(localized: "Cancel", comment: "Cancel removal."), role: .cancel) {}
                Button(String(localized: "Remove", comment: "Confirm removal."), role: .destructive) { performRemove() }
            } message: {
                Text(confirmMessage)
            }
    }

    private func applyFocus() {
        guard let focus else { return }
        section = .privacy
        search = ""
        if case .browser(let browser) = focus { selectedBrowser = browser }
        self.focus = nil
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
                // The title-bar safe-area extension is applied by
                // ProtectionDashboardView, outside the manager zoom
                // transition — see ManagerSurfaceModifier.
                .tint(accent)
                .environment(\.sectionAccent, accent)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").foregroundStyle(.tint)
                    Text(String(localized: "Back", comment: "Back button on the Protection Manager."))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("protection.manager.back")
            Spacer()
            Text(String(localized: "Protection Manager", comment: "Protection Manager screen title.")).font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tint)
                TextField(String(localized: "Search", comment: "Manager search placeholder."), text: $search)
                    .textFieldStyle(.plain).frame(width: 130)
                    .accessibilityIdentifier("protection.manager.search")
            }
            // Threats have no count to sort by, so the menu is only for Privacy.
            if section == .privacy {
                Menu {
                    ForEach(Sort.allCases) { option in Button(option.label) { sort = option } }
                } label: {
                    // One Text, because a borderless Menu draws only the first
                    // view of a compound label and the current sort went missing.
                    Text("\(Text(String(localized: "Sort by:", comment: "Manager sort label.")).foregroundStyle(.secondary)) \(Text(sort.label).foregroundStyle(.tint))")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("protection.manager.sort")
            }
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
                        description: String(
                            localized: "Remove the cookies, download history, cached files, and tabs your browsers keep. Browsing history, passwords, and autofill are shown for your information.",
                            comment: "Privacy middle description."
                        ),
                        bottomPadding: 8
                    )
                    if privacyModel.browsers.isEmpty && privacyModel.phase == .scanning {
                        ProgressView().padding(.top, 12)
                    }
                    ForEach(browserRows) { browser in browserRow(browser) }
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
                    Text(ProtectionCopy.items(privacyModel.removableCount(browser))).font(.caption).foregroundStyle(.secondary)
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
                Text(ProtectionCopy.items(threats.count)).font(.caption).foregroundStyle(.secondary)
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
            if browserRows.isEmpty && !search.isEmpty {
                ManagerEmptyState(
                    icon: "magnifyingglass",
                    title: String(localized: "No Matches", comment: "Protection Manager empty search title."),
                    detail: String(localized: "Nothing here matches your search.", comment: "Protection Manager empty search detail.")
                )
                .tint(Self.accent)
            } else if let browser = selectedBrowser {
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
            malwarePane
        }
    }

    /// The Malware pane says only what the last scan supports. "No threats" is
    /// the answer to a finished scan, never to a stopped, failed, or missing one.
    @ViewBuilder
    private var malwarePane: some View {
        switch malware.threatListState {
        case .scanning:
            MalwareScanningPlaceholder()
        case .removing:
            VStack(spacing: 14) {
                ProgressView()
                Text(String(localized: "Removing threats…", comment: "Protection Manager malware pane while removing."))
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .threats(let listed):
            MalwareResultsPane(
                threats: listed,
                search: search,
                unreadableNote: malware.unreadableNote,
                selectedThreats: $selectedThreats,
                accent: Self.accent
            )
        case .clean:
            malwareStatus(
                icon: "checkmark.shield.fill",
                title: String(localized: "No Threats Found", comment: "Empty threats title."),
                detail: malware.cleanResultDescription
            )
        case .removed(let count):
            malwareStatus(
                icon: "checkmark.shield.fill",
                title: ProtectionCopy.threatsRemoved(count),
                detail: String(localized: "The infected files have been removed.", comment: "Malware pane detail after removal.")
            )
        case .notScanned:
            malwareStatus(
                icon: "questionmark.circle",
                title: String(localized: "No Scan Results", comment: "Malware pane title when no scan has finished."),
                detail: String(localized: "The last scan didn't finish, so this can't say whether your Mac has any threats.", comment: "Malware pane detail when no scan has finished."),
                offersScan: true
            )
        case .failed(let message):
            malwareStatus(
                icon: "exclamationmark.triangle",
                title: String(localized: "Scan Failed", comment: "Malware pane title after a failed scan."),
                detail: message,
                offersScan: true
            )
        case .engineMissing:
            malwareStatus(
                icon: "exclamationmark.triangle",
                title: String(localized: "Malware Engine Unavailable", comment: "Malware pane title when ClamAV is missing."),
                detail: String(localized: "Your Mac couldn't be scanned because the malware engine is missing.", comment: "Malware pane detail when ClamAV is missing.")
            )
        }
    }

    private func malwareStatus(icon: String, title: String, detail: String, offersScan: Bool = false) -> some View {
        VStack(spacing: 16) {
            ManagerEmptyState(icon: icon, title: title, detail: detail)
                .frame(maxHeight: .infinity)
            if offersScan {
                Button(String(localized: "Scan Now", comment: "Starts a malware scan from the Protection Manager.")) {
                    malware.beginScan()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("protection.manager.malware.scan")
            }
        }
        .tint(Self.accent)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("protection.manager.malware.status")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if privacyModel.phase == .removing {
                ProgressView().controlSize(.small)
            }
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

    /// The ticked threats still on the list, in list order.
    private var selectedThreatList: [MalwareThreat] {
        threats.filter { selectedThreats.contains($0.id) }
    }

    /// The browsers search leaves on offer, most items first when sorting by count.
    private var browserRows: [Browser] {
        let matching = privacyModel.browsers.filter { privacyModel.browserMatches($0, search: search) }
        guard sort == .count else { return matching }
        return matching.sorted { privacyModel.removableCount($0) > privacyModel.removableCount($1) }
    }

    private var canRemove: Bool {
        switch section {
        case .privacy: return privacyModel.hasSelection && privacyModel.phase != .removing
        case .malware: return !selectedThreatList.isEmpty
        }
    }

    private var selectionSummary: String {
        switch section {
        case .privacy:
            let n = privacyModel.selectedCount
            return n == 0
                ? String(localized: "No Privacy Items Selected", comment: "Empty privacy selection.")
                : ProtectionCopy.privacyItemsSelected(n)
        case .malware:
            let n = selectedThreatList.count
            return n == 0
                ? String(localized: "No Threats Selected", comment: "Empty threat selection.")
                : ProtectionCopy.threatsSelected(n)
        }
    }

    private var confirmTitle: String {
        String(localized: "Remove selected items?", comment: "Removal confirmation title.")
    }

    /// Both bodies name what will go. A selection can span browsers the user isn't
    /// looking at, and search can hide a ticked row. Privacy data is deleted
    /// outright; threats go to the Trash unless one sits under a protected path,
    /// which the message then warns about.
    private var confirmMessage: String {
        switch section {
        case .privacy:
            let warning = String(localized: "The selected items will be permanently deleted. This cannot be undone.",
                                 comment: "Protection Manager removal confirmation body.")
            return ([warning] + privacyModel.removalSummaryLines).joined(separator: "\n\n")
        case .malware:
            return selectedThreatList.namedRemovalConfirmationMessage
        }
    }

    private func performRemove() {
        switch section {
        case .privacy:
            Task { await privacyModel.remove() }
        case .malware:
            let selected = selectedThreatList
            // On a failure the manager stays up, with what's left still listed
            // and ticked, while the host's alert says what happened.
            Task {
                await malware.removeThreats(selected)
                if malware.threatRemovalFailureCount == 0 { onBack() }
            }
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
                    any: model.hasSelection(in: browser),
                    onAll: { model.setAllSelected(true, browser: browser, search: search) },
                    onNone: { model.setAllSelected(false, browser: browser, search: search) }
                )
                // Each category (with its expanded per-item rows) sits on its
                // own rounded glass card, matching the manager card rows used
                // across the app's other sections.
                //
                // The expanded rows are a `LazyVStack` because their count is
                // the browser's, not ours: cookies and history are grouped per
                // host, and a well-used profile has thousands of them. Built
                // eagerly, one expanded category cost 555ms of layout at 3,000
                // hosts and 2.2s at 10,000 — and re-paid it on every keystroke
                // in the search field, since the filter runs in `body`.
                VStack(spacing: 10) {
                    ForEach(visibleCategories) { category in
                        VStack(spacing: 0) {
                            categoryRow(category)
                            if showsItems(category) {
                                LazyVStack(spacing: 0) {
                                    ForEach(sortedItems(category)) { item in
                                        itemRow(category, item)
                                    }
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
            SmartInsightsSparkle(itemTitle: category.displayName, accent: accent, topic: .privacyData)
            // Fixed-width count column so the sparkle to its left lines up across
            // every row regardless of how wide each item count is.
            Text(countLabel(category))
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
                .help(availabilityHelp(category))
            // Only offer the disclosure chevron when the category can expand AND
            // actually has items to reveal — an empty category shows no chevron.
            if category.isExpandable && model.count(browser, category) > 0 {
                Button { toggleExpanded(category) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        .rotationEffect(.degrees(showsItems(category) ? 90 : 0))
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
            // An empty category has nothing to tick.
            ManagerCheckbox(state: model.categoryState(browser, category), accent: accent) {
                model.toggleCategory(browser, category)
            }
            .disabled(model.count(browser, category) == 0)
            .opacity(model.count(browser, category) == 0 ? 0.4 : 1)
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
            SmartInsightsSparkle(itemTitle: item.label, accent: accent, topic: .privacyData)
            Text(ProtectionCopy.items(item.count))
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Color.clear.frame(width: 20, height: 1)
        }
        .padding(.vertical, 7).padding(.leading, 34)
        .background(Color.primary.opacity(0.02))
    }

    /// Zero only means "nothing there" for data the app can read. Anything else
    /// says so, rather than passing off "couldn't look" as "all clear".
    private func countLabel(_ category: ProtectionPrivacyCategory) -> String {
        switch model.availability(browser, category) {
        case .available:
            return ProtectionCopy.items(model.count(browser, category))
        case .unsupported:
            return String(localized: "Not available", comment: "Privacy category the app can't read for this browser.")
        case .unreadable:
            return String(localized: "Needs access", comment: "Privacy category the app isn't allowed to read.")
        }
    }

    private func availabilityHelp(_ category: ProtectionPrivacyCategory) -> String {
        switch model.availability(browser, category) {
        case .available:
            return ""
        case .unsupported:
            return String(
                localized: "VaderCleaner can't read this kind of data from \(browser.displayName).",
                comment: "Tooltip on a privacy category the app can't read for this browser."
            )
        case .unreadable:
            return String(
                localized: "macOS is keeping this data private. Give VaderCleaner Full Disk Access in System Settings to include it.",
                comment: "Tooltip on a privacy category the app isn't allowed to read."
            )
        }
    }

    /// The categories search leaves on screen, most items first when sorting by count.
    private var visibleCategories: [ProtectionPrivacyCategory] {
        let matching = ProtectionPrivacyCategory.allCases.filter { model.isCategoryVisible(browser, $0, search: search) }
        guard sortByCount else { return matching }
        return matching.sorted { model.count(browser, $0) > model.count(browser, $1) }
    }

    /// A search that matched rows inside a category opens it, or the matches would
    /// sit hidden behind a collapsed row. One that named the category itself
    /// leaves the disclosure as the user set it.
    private func showsItems(_ category: ProtectionPrivacyCategory) -> Bool {
        if isExpanded(category) { return true }
        guard !search.isEmpty, category.isExpandable else { return false }
        return !category.displayName.localizedCaseInsensitiveContains(search)
            && !model.visibleItems(browser, category, search: search).isEmpty
    }

    private func sortedItems(_ category: ProtectionPrivacyCategory) -> [PrivacyItem] {
        let items = model.visibleItems(browser, category, search: search)
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

/// The right pane's Malware content when a scan found something: the detected
/// threats with per-file selection. Derives its own filtered/sorted threat list.
private struct MalwareResultsPane: View {

    let threats: [MalwareThreat]
    let search: String
    let unreadableNote: String?
    @Binding var selectedThreats: Set<String>
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PaneHeading(
                    title: String(localized: "Detected Threats", comment: "Threats pane title."),
                    description: paneDescription
                )
                if sortedThreats.isEmpty {
                    ManagerEmptyState(
                        icon: "magnifyingglass",
                        title: String(localized: "No Matches", comment: "Protection Manager empty search title."),
                        detail: String(localized: "Nothing here matches your search.", comment: "Protection Manager empty search detail.")
                    )
                    .tint(accent)
                    .padding(.top, 40)
                } else {
                    // Select and Deselect act on the rows on screen, so a search
                    // can't tick or untick anything it's hiding.
                    ManagerSelectMenu(
                        any: !selectedThreats.isDisjoint(with: sortedThreats.map(\.id)),
                        onAll: { selectedThreats.formUnion(sortedThreats.map(\.id)) },
                        onNone: { selectedThreats.subtract(sortedThreats.map(\.id)) }
                    )
                    // Lazy for the same reason as the privacy rows: a full-disk
                    // ClamAV scan decides how many threats land here, and the
                    // list is uncapped.
                    LazyVStack(spacing: 10) {
                        ForEach(sortedThreats) { threat in threatRow(threat) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
    }

    private var paneDescription: String {
        let description = String(
            localized: "Select the infected files to remove. They go to the Trash, except files in system folders, which are deleted permanently.",
            comment: "Threats pane description."
        )
        return unreadableNote.map { "\(description) \($0)" } ?? description
    }

    private func threatRow(_ threat: MalwareThreat) -> some View {
        HStack(spacing: 12) {
            ManagerCheckbox(state: selectedThreats.contains(threat.id) ? .on : .off, accent: accent) {
                if selectedThreats.contains(threat.id) { selectedThreats.remove(threat.id) } else { selectedThreats.insert(threat.id) }
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
            .filter { search.isEmpty || $0.threatName.localizedCaseInsensitiveContains(search) || $0.filePath.path.localizedCaseInsensitiveContains(search) }
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

/// The Protection screens' counted labels, whose singulars come from the
/// app's stringsdict.
enum ProtectionCopy {
    static func items(_ count: Int) -> String {
        String(localized: "\(count) items", comment: "Item count label.")
    }

    static func threatsFound(_ count: Int) -> String {
        String(localized: "\(count) Threats Found", comment: "Malware tile title when threats are found.")
    }

    static func threatsRemoved(_ count: Int) -> String {
        String(localized: "\(count) Threats Removed", comment: "Malware tile title after removal.")
    }

    static func threatsSelected(_ count: Int) -> String {
        String(localized: "\(count) Threats Selected", comment: "Threat selection count.")
    }

    static func privacyItemsSelected(_ count: Int) -> String {
        String(localized: "\(count) Privacy Items Selected", comment: "Privacy selection count.")
    }
}
