// SmartScanReviewManager.swift
// Reusable three-pane "Manager" shell for every Smart Scan Review screen — sections list, category list with size badges, and a per-item checkbox list, with search, sort, and a live selected-count footer. The item model is Sendable and built off the main thread so opening a manager over tens of thousands of files never blocks the UI.

import SwiftUI

/// Icon tint for a manager row. A plain `Sendable` enum (rather than a SwiftUI
/// `Color`) so the whole item model can be built off the main actor; the view
/// maps it to a `Color` at render time.
enum ManagerTint: Sendable, Hashable {
    case green, blue, red, orange, purple, secondary

    var color: Color {
        switch self {
        case .green: return .green
        case .blue: return .blue
        case .red: return .red
        case .orange: return .orange
        case .purple: return .purple
        case .secondary: return .secondary
        }
    }
}

/// One selectable leaf row in the manager's right-hand pane. Fully `Sendable`
/// with a precomputed `sizeText` so building and scrolling never touch a
/// `ByteCountFormatter` (which is slow per-row and stutters large lists).
struct ManagerItem: Identifiable, Hashable, Sendable {
    /// Stable selection key (e.g. a file URL's path or a bundle id).
    let id: String
    let title: String
    let subtitle: String?
    /// Byte size, when the item has one. Used for sorting; `nil` for items not
    /// measured in bytes (e.g. app updates).
    let size: Int64?
    /// Pre-rendered size string, or `nil` for sizeless items.
    let sizeText: String?
    let systemImage: String
    let tint: ManagerTint
    /// When true the row shows the real Finder icon for the file at `id` (a file
    /// path) instead of `systemImage` — used by the Cleanup Manager so app and
    /// document rows look like Finder. Other managers leave this off and keep
    /// their tinted SF Symbol.
    var usesFileIcon: Bool = false
    /// Filesystem path the Finder icon is drawn from when `usesFileIcon` is set
    /// and the row's selection `id` is *not* itself a path (e.g. a login item
    /// keyed by bundle id, or a launch agent whose app bundle differs from its
    /// plist). `nil` falls back to `id`.
    var iconPath: String? = nil
    /// Immediate children revealed when this row is expanded (one level only).
    /// Empty for leaf rows and for managers that don't show a tree.
    var children: [ManagerItem] = []
    /// Indentation depth: 0 for a top-level row, 1 for an expanded child.
    var indentLevel: Int = 0
    /// Leaf file paths this row covers, for aggregate folder selection. A leaf
    /// file is `[its path]`; a folder is every scanned file beneath it. Empty
    /// for managers whose selection is keyed directly by `id`.
    var selectionPaths: [String] = []

    /// Whether this row has children to disclose.
    var isExpandable: Bool { !children.isEmpty }
}

/// One extra entry in a category's "Select:" menu, below Select All / Deselect
/// All. Hosts supply the category-specific picks (the Cleanup Manager's idle
/// projects filter); the manager only renders them and calls `apply`.
struct ManagerSelectFilter: Identifiable {
    let id: String
    let title: String
    let apply: () -> Void
}

/// A group of items shown in the manager's middle pane. Its items are stored
/// pre-sorted by size (descending) by the builder, so the default view needs no
/// main-thread sort.
struct ManagerCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let tint: ManagerTint
    /// Asset-catalog name of the glossy 3D badge shown for the category. When
    /// `nil` the row falls back to the tinted `systemImage`. The Cleanup Manager
    /// sets this so its categories match the dashboard's badge artwork.
    var badgeAsset: String? = nil
    let items: [ManagerItem]
    /// Sum of the category's item sizes, or `nil` when its items carry no size.
    let totalSize: Int64?
    /// Pre-rendered total size string for the badge, or `nil`.
    let totalSizeText: String?
    /// One-line explanation shown as the right pane's header when this category
    /// is selected. `nil` hides the header.
    var description: String? = nil
}

/// A top-level grouping shown in the manager's left pane (e.g. "System Junk",
/// "Mail Attachments", "Trash").
struct ManagerSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let categories: [ManagerCategory]
    /// One-line explanation shown as the middle pane's header when this section
    /// is selected. `nil` hides the header.
    var description: String? = nil
}

/// Pre-tallied selection totals for the footer, so it doesn't have to scan
/// every item on each render. `bytes` is `nil` for tiles whose items carry no
/// size (e.g. app updates, threats).
struct ManagerSelectionSummary {
    let count: Int
    let bytes: Int64?
}

/// Fast, thread-safe byte formatter for the high-volume manager rows.
/// `ByteCountFormatter` is too slow to call per row (it stutters scrolling) and
/// isn't safe to share across threads; this approximates its file-style output
/// (1000-based units) cheaply so sizes can be precomputed off the main actor.
enum ManagerByteText {
    static func string(_ bytes: Int64) -> String {
        if bytes < 1000 {
            return String.localizedStringWithFormat(
                String(localized: "%lld bytes", comment: "Byte count under 1 KB in a Smart Scan Manager row."),
                bytes
            )
        }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1000
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

/// How the manager orders categories and items.
enum ManagerSort: String, CaseIterable, Identifiable {
    case size
    case name
    var id: String { rawValue }

    var label: String {
        switch self {
        case .size:
            return String(localized: "Size", comment: "Manager sort option ordering by byte size, largest first.")
        case .name:
            return String(localized: "Name", comment: "Manager sort option ordering alphabetically by name.")
        }
    }
}

/// Reusable three-pane Cleanup-Manager-style Review shell. The data model is
/// produced by an async `buildSections` closure that runs off the main actor,
/// so opening a manager over a huge scan shows the chrome immediately and fills
/// in when the model is ready. Selection is owned by the caller (the view
/// model) and read through `isSelected` / driven through `onToggle` /
/// `onSetCategory`.
struct SmartScanReviewManager: View {
    let title: String
    /// Builds the (Sendable) section model off the main actor.
    let buildSections: @Sendable () async -> [ManagerSection]
    /// Whether a leaf item (by `ManagerItem.id`) is currently checked. Unused
    /// when `showsSelection` is false.
    var isSelected: (String) -> Bool = { _ in false }
    /// Flip a single item's checked state. Unused when `showsSelection` is false.
    var onToggle: (String) -> Void = { _ in }
    /// Bulk select/clear every item in a category (the "Select" menu). Unused
    /// when `showsSelection` is false.
    var onSetCategory: (ManagerCategory, Bool) -> Void = { _, _ in }
    /// Category-specific bulk-select picks, listed below Select All / Deselect
    /// All. Empty for categories with nothing extra to offer.
    var categorySelectFilters: (ManagerCategory) -> [ManagerSelectFilter] = { _ in [] }
    /// Total bytes currently selected within a category, for the middle-pane
    /// badge. Returns `nil` (no badge) when the caller doesn't track it or
    /// nothing in the category is selected.
    var categorySelectedBytes: (ManagerCategory) -> Int64? = { _ in nil }
    /// Optional O(1) per-category selection tally — the number of leaf items
    /// selected in a category and its total item count — so the bulk-select
    /// menu's None/All/Some state needn't scan every row (and, for hierarchical
    /// managers, every file beneath each folder row) on each render. `nil` falls
    /// back to a per-row `isSelected` scan, which is fine for the small flat
    /// managers but is the walk that delayed the Cleanup Manager's checkbox
    /// repaint on large scans.
    var categorySelectionTally: (ManagerCategory) -> (selected: Int, total: Int)? = { _ in nil }
    /// Builds the rows for one category on demand (by `ManagerCategory.id`). When
    /// set, `buildSections` only needs to return the lightweight shell and each
    /// category's rows are loaded lazily here. `nil` keeps the eager behavior
    /// where the rows live on `ManagerCategory.items`.
    var loadItems: (@Sendable (String) async -> [ManagerItem])? = nil
    let onBack: () -> Void
    /// Accessibility-identifier root, e.g. "smartScan.review.junk".
    let accessibilityPrefix: String
    /// When false the manager is read-only: item rows lose their checkboxes,
    /// the per-category "Select" menu is hidden, and the footer shows a plain
    /// item count instead of a selected-count.
    var showsSelection: Bool = true
    /// When true the manager renders on a white, light-mode surface (matching
    /// the reference Cleanup Manager) instead of inheriting the section's dark
    /// gradient. Smart Scan's managers leave this off.
    var lightSurface: Bool = false
    /// When true each item row shows a decorative pink "smart suggestion"
    /// sparkle (non-interactive). Off for Smart Scan's managers.
    var showsSparkle: Bool = false
    /// Section/category to pre-select when the manager opens, for deep linking
    /// from a dashboard card's "Review". `nil` falls back to the first section
    /// and that section's first category.
    var initialSectionID: String? = nil
    var initialCategoryID: String? = nil
    /// Whether the manager is the visible surface. Hosts that keep the manager
    /// alive between opens (hidden behind the dashboard) flip this so each
    /// open re-aims the panes at the deep-link target; a host that removes the
    /// manager on Back can leave it `true`.
    var isPresented: Bool = true
    /// Optional secondary footer button shown left of the primary action.
    var secondaryActionTitle: String? = nil
    var onSecondaryAction: (() -> Void)? = nil
    /// Optional override for the prominent primary footer button. When `nil` the
    /// footer shows "Done" wired to `onBack` (the Smart Scan default); supplying
    /// a title (e.g. "Clean Up") swaps the label and runs `onPrimaryAction`,
    /// disabled while `primaryActionEnabled` is false.
    var primaryActionTitle: String? = nil
    var onPrimaryAction: (() -> Void)? = nil
    var primaryActionEnabled: Bool = true
    /// Optional cheap selection tally for the footer, so it needn't scan every
    /// item on each render. `nil` falls back to a full scan (fine for the small
    /// flat tiles).
    var selectionSummary: (() -> ManagerSelectionSummary)? = nil
    /// Monotonic counter the host bumps on every selection change, forwarded to
    /// the row table so it refreshes visible checkbox state only when the
    /// selection actually moved — not on the incidental SwiftUI updates that
    /// fire throughout a momentum scroll. `nil` (the default) makes the small
    /// flat managers always refresh, so their checkboxes repaint on every
    /// toggle; only the Cleanup Manager, over huge scans, supplies a revision.
    var selectionToken: Int? = nil

    /// The active section accent (purple in Smart Scan), used to tint the
    /// section/category selection so it matches the app rather than the grey
    /// system list highlight.
    @Environment(\.sectionAccent) private var accent

    /// The model, `nil` until the off-main build finishes (loading state).
    @State private var sections: [ManagerSection]?
    @State private var selectedSectionID: String?
    @State private var selectedCategoryID: String?
    @State private var search = ""
    @State private var sort: ManagerSort = .size
    /// IDs of the expanded top-level rows, so each disclosed row reveals its
    /// one level of children. Cleared when the visible category changes.
    @State private var expandedIDs: Set<String> = []
    /// The filtered + sorted items for the visible category — flattened to
    /// include the children of any expanded row. Recomputed when the category,
    /// sort, search, or expansion changes — never on a selection toggle.
    @State private var displayedItems: [ManagerItem] = []
    /// Reload token for `displayedItems`, rebuilt alongside it (see
    /// `ManagerItemTable.contentToken`) so the O(n) id hash runs once per
    /// content change instead of once per render.
    @State private var displayedToken = ""
    /// Lazily-loaded rows per category id (when `loadItems` is set), cached for
    /// this manager session.
    @State private var lazyItemsByCategory: [String: [ManagerItem]] = [:]
    /// Category id whose rows are being loaded lazily right now. Tracked by id
    /// (not a plain flag) so a load superseded by a category switch can't
    /// clear — or leave stuck — the newer load's spinner.
    @State private var loadingCategoryID: String?

    /// True while the *selected* category's rows are being loaded lazily.
    private var isLoadingItems: Bool {
        loadingCategoryID != nil && loadingCategoryID == selectedCategoryID
    }

    private var loadedSections: [ManagerSection] { sections ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if sections == nil {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sectionPane
                    Divider().opacity(0.4)
                    categoryPane
                    Divider().opacity(0.4)
                    itemPane
                }
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ManagerSurfaceModifier(light: lightSurface))
        .accessibilityIdentifier(accessibilityPrefix)
        .task {
            // Build off the main actor so a huge scan never beach-balls the UI.
            let built = await Task.detached(priority: .userInitiated) {
                await buildSections()
            }.value
            sections = built
            syncSelection()
            refreshDisplayedItems()
        }
        .onChange(of: selectedCategoryID) { _, _ in
            // A fresh category starts fully collapsed.
            expandedIDs = []
        }
        // Load the selected category's rows (lazily when `loadItems` is set),
        // then refresh the visible list. Runs on first appearance and whenever
        // the category changes.
        .task(id: selectedCategoryID) {
            await loadSelectedCategoryIfNeeded()
            refreshDisplayedItems()
        }
        .onChange(of: sort) { _, _ in refreshDisplayedItems() }
        .onChange(of: search) { _, _ in refreshDisplayedItems() }
        // A manager kept alive by its host between opens re-aims its panes on
        // each open: a fresh instance honors the deep-link ids in
        // `syncSelection`, but a retained one must follow them explicitly.
        // `nil` ids (Review All) leave the panes where the user left them.
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            applyDeepLinkTarget()
        }
    }

    /// Aim the panes at the host's current deep-link target, if any: the
    /// section when it names one in the model, then its category — or that
    /// section's first category when the category id doesn't resolve,
    /// mirroring `syncSelection`. No-op when both ids are `nil`, so a plain
    /// (non-deep-linked) reopen resumes in place.
    private func applyDeepLinkTarget() {
        guard initialSectionID != nil || initialCategoryID != nil else { return }
        if let target = initialSectionID, loadedSections.contains(where: { $0.id == target }) {
            selectedSectionID = target
        }
        if let target = initialCategoryID, sortedCategories.contains(where: { $0.id == target }) {
            selectedCategoryID = target
        } else if initialSectionID != nil {
            selectFirstCategory()
        }
    }

    /// Builds the selected category's rows on demand when `loadItems` is set,
    /// caching them for this session. No-op for eager managers.
    private func loadSelectedCategoryIfNeeded() async {
        guard let loadItems, let id = selectedCategoryID, lazyItemsByCategory[id] == nil else { return }
        loadingCategoryID = id
        let built = await loadItems(id)
        // Guard against the category having changed while loading: the cache
        // still accepts the stale build (it's valid for its category), but
        // only the load that is still current may clear the loading marker.
        lazyItemsByCategory[id] = built
        if loadingCategoryID == id { loadingCategoryID = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").foregroundStyle(.tint)
                    Text(String(localized: "Back", comment: "Back button on a Smart Scan Manager screen."))
                }
            }
            .buttonStyle(.plain)
            // Shared id (not prefixed) so the one Back affordance on screen is
            // queryable the same way across every Manager — UI tests rely on it.
            .accessibilityIdentifier("smartScan.review.back")

            Spacer()
            Text(title).font(.headline)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tint)
                TextField(
                    String(localized: "Search", comment: "Placeholder in a Smart Scan Manager search field."),
                    text: $search
                )
                .textFieldStyle(.plain)
                .frame(width: 140)
                .accessibilityIdentifier("\(accessibilityPrefix).search")
            }

            Menu {
                ForEach(ManagerSort.allCases) { option in
                    Button(option.label) { sort = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "Sort by:", comment: "Label preceding the sort option on a Smart Scan Manager."))
                        .foregroundStyle(.secondary)
                    Text(sort.label).foregroundStyle(.tint)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("\(accessibilityPrefix).sort")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Panes

    private var sectionPane: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(loadedSections) { section in
                    NavRow(selected: section.id == selectedSection?.id) {
                        selectedSectionID = section.id
                        selectFirstCategory()
                    } content: {
                        Text(section.title)
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 200)
    }

    private var categoryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header describing the selected section.
            if let section = selectedSection, let description = section.description {
                paneHeader(title: section.title, description: description)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sortedCategories) { category in
                        NavRow(selected: category.id == selectedCategory?.id) {
                            selectedCategoryID = category.id
                        } content: {
                            categoryRow(category)
                        }
                        .accessibilityIdentifier("\(accessibilityPrefix).category.\(category.id)")
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 280)
    }

    /// The title + one-line description shown atop the middle and right panes,
    /// reflecting the selected section/category.
    private func paneHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func categoryRow(_ category: ManagerCategory) -> some View {
        HStack(spacing: 12) {
            if let badge = category.badgeAsset {
                Image(badge)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
            } else {
                icon(category.systemImage, category.tint.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Pinned to one line each: when the selected-size badge appears
                // it steals trailing width, and an unconstrained title would wrap
                // to a second line — growing the row and reflowing the whole
                // middle pane on every checkbox toggle.
                Text(category.title).font(.body.weight(.medium))
                    .lineLimit(1)
                if let text = category.totalSizeText {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(category.items.count) item\(category.items.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // Selected-size badge: the running total of what's checked in this
            // category. Hidden when nothing is selected.
            if let selectedBytes = categorySelectedBytes(category), selectedBytes > 0 {
                Text(ManagerByteText.string(selectedBytes))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent, in: Capsule())
            }
        }
    }

    private var itemPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedCategory != nil {
                // Header describing the selected category.
                if let category = selectedCategory, let description = category.description {
                    paneHeader(title: category.title, description: description)
                }
                if showsSelection, let category = selectedCategory {
                    // Counts come from the visible (loaded) rows, not the shell
                    // category, which carries no items when loading is lazy.
                    let rows = currentCategoryItems
                    let state = bulkSelectionState(category: category, rows: rows)
                    HStack(spacing: 8) {
                        Text(String(localized: "Select:", comment: "Label before the bulk-select menu on a Smart Scan Manager."))
                            .foregroundStyle(.secondary)
                        Menu {
                            Button(String(localized: "Select All", comment: "Bulk-select every item in the category.")) {
                                onSetCategory(category, true)
                            }
                            .disabled(state == .all)
                            Button(String(localized: "Deselect All", comment: "Bulk-deselect every item in the category.")) {
                                onSetCategory(category, false)
                            }
                            .disabled(state == .none)
                            let filters = categorySelectFilters(category)
                            if !filters.isEmpty {
                                Divider()
                                ForEach(filters) { filter in
                                    Button(filter.title) { filter.apply() }
                                }
                            }
                        } label: {
                            Text(state.label)
                                .foregroundStyle(.tint)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityIdentifier("\(accessibilityPrefix).select")
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                if isLoadingItems && displayedItems.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedItems.isEmpty {
                    ManagerEmptyState(
                        icon: "checkmark.seal.fill",
                        title: String(localized: "Nothing to review", comment: "Empty state title in a Smart Scan Manager's detail pane."),
                        detail: String(localized: "There are no items to clean or fix in this area.\nEverything is in order.", comment: "Empty state detail in a Smart Scan Manager's detail pane.")
                    )
                    .accessibilityIdentifier("\(accessibilityPrefix).empty")
                } else {
                    ManagerItemTable(
                        items: displayedItems,
                        showsSelection: showsSelection,
                        isSelected: rowIsSelected,
                        onToggle: onToggle,
                        accent: accent,
                        // Tall enough for the 38-point icon plus the card's
                        // interior padding and 4-point vertical card inset.
                        rowHeight: 68,
                        // Key the table reload to the *actual* displayed rows, not
                        // the inputs: `selectedCategoryID` changes a render before
                        // `displayedItems` is recomputed, so an input-based token
                        // would reload with the previous category's row count and
                        // then skip the reload once the real rows arrive — leaving
                        // stale, unconfigured cells. The token is precomputed in
                        // `refreshDisplayedItems` so its O(n) id hash never runs
                        // per render.
                        contentToken: displayedToken,
                        selectionToken: selectionToken,
                        accessibilityPrefix: accessibilityPrefix,
                        forcesLightAppearance: lightSurface,
                        showsSparkle: showsSparkle,
                        isExpanded: { expandedIDs.contains($0) },
                        onToggleExpand: { toggleExpand($0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ManagerEmptyState(
                    icon: "checkmark.seal.fill",
                    title: String(localized: "Nothing to review", comment: "Empty state in a Smart Scan Manager's detail pane."),
                    detail: String(localized: "There are no items to clean or fix in this area.\nEverything is in order.", comment: "Empty state detail when no category is selected in a Smart Scan Manager.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerSummary)
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("\(accessibilityPrefix).summary")
            Spacer()
            if let secondaryActionTitle, let onSecondaryAction {
                Button(secondaryActionTitle, action: onSecondaryAction)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(accessibilityPrefix).secondary")
            }
            Button(
                primaryActionTitle ?? String(localized: "Done", comment: "Confirms the Manager selection and returns to the Smart Scan dashboard."),
                action: onPrimaryAction ?? onBack
            )
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            // Only the custom primary action (e.g. Clean Up) gates on enablement;
            // the default "Done" is always available.
            .disabled(primaryActionTitle != nil && !primaryActionEnabled)
            .accessibilityIdentifier("\(accessibilityPrefix).done")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var footerSummary: String {
        // Read-only managers (e.g. Performance) show a plain item count — their
        // rows have no checkbox, so a "selected" count would be meaningless.
        guard showsSelection else {
            let total = loadedSections.reduce(0) { $0 + $1.categories.reduce(0) { $0 + $1.items.count } }
            return String.localizedStringWithFormat(
                String(localized: "%lld items", comment: "Plain item count in a read-only Smart Scan Manager footer."),
                total
            )
        }
        let summary = selectionSummary?() ?? scannedSelectionSummary()
        let countText = summary.count == 0
            ? String(localized: "No Items Selected", comment: "Smart Scan Manager footer when nothing is selected.")
            : String.localizedStringWithFormat(
                String(localized: "%lld Items Selected", comment: "Live count of selected items in a Smart Scan Manager footer."),
                summary.count
            )
        guard let bytes = summary.bytes else { return countText }
        return "\(countText)  ·  \(ManagerByteText.string(bytes))"
    }

    /// Full-scan fallback used only when the caller didn't supply a cheap
    /// `selectionSummary` — fine for the small flat tiles (threats, updates),
    /// never hit by the file tiles.
    private func scannedSelectionSummary() -> ManagerSelectionSummary {
        var count = 0
        var bytes: Int64 = 0
        var hasSized = false
        for section in loadedSections {
            for category in section.categories {
                for item in category.items where isSelected(item.id) {
                    count += 1
                    if let size = item.size { bytes += size; hasSized = true }
                }
            }
        }
        return ManagerSelectionSummary(count: count, bytes: hasSized ? bytes : nil)
    }

    // MARK: - Derived data

    /// The per-row checkbox predicate for the visible category. When the
    /// category's O(1) tally reports a uniform state — everything or nothing
    /// selected — every row answers without the caller's per-row check, which
    /// for the hierarchical managers walks the row's whole subtree; over a
    /// large scan (whose default state is a fully-checked category) those
    /// walks stalled every open of the manager for seconds. Mixed selections
    /// fall back to the caller's check, which then short-circuits on the
    /// unselected files.
    private var rowIsSelected: (String) -> Bool {
        guard let category = selectedCategory,
              let uniform = Self.uniformSelection(tally: categorySelectionTally(category)) else {
            return isSelected
        }
        return { _ in uniform }
    }

    /// Maps a category's selection tally to its uniform state: `true` when
    /// every leaf item is selected, `false` when none is, `nil` when mixed or
    /// unknown (no tally, or an empty category) — only then do the row
    /// checkboxes need a real per-row answer.
    static func uniformSelection(tally: (selected: Int, total: Int)?) -> Bool? {
        guard let tally, tally.total > 0 else { return nil }
        if tally.selected == 0 { return false }
        if tally.selected >= tally.total { return true }
        return nil
    }

    /// The selected category's rows — lazily loaded when `loadItems` is set,
    /// otherwise the eager rows carried on the category.
    private var currentCategoryItems: [ManagerItem] {
        if loadItems != nil {
            return selectedCategoryID.flatMap { lazyItemsByCategory[$0] } ?? []
        }
        return selectedCategory?.items ?? []
    }

    private var selectedSection: ManagerSection? {
        loadedSections.first { $0.id == selectedSectionID } ?? loadedSections.first
    }

    private var sortedCategories: [ManagerCategory] {
        let categories = selectedSection?.categories ?? []
        switch sort {
        case .size:
            return categories.sorted { ($0.totalSize ?? 0) > ($1.totalSize ?? 0) }
        case .name:
            return categories.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private var selectedCategory: ManagerCategory? {
        sortedCategories.first { $0.id == selectedCategoryID } ?? sortedCategories.first
    }

    /// Rebuild the visible item list. Called only when the category, sort,
    /// search, or expansion changes — never on a selection toggle. The builder
    /// pre-sorts each category by size, so the default view (size, no search)
    /// needs no top-level sort. Expanded rows are followed by their (already
    /// size-sorted) children.
    private func refreshDisplayedItems() {
        guard selectedCategory != nil else {
            displayedItems = []
            displayedToken = ManagerItemTable.contentToken(items: [], sort: sort.rawValue, search: search)
            return
        }
        let categoryItems = currentCategoryItems
        let filtered = search.isEmpty
            ? categoryItems
            : categoryItems.filter { $0.title.localizedCaseInsensitiveContains(search) }
        let topLevel: [ManagerItem]
        switch sort {
        case .size:
            topLevel = search.isEmpty ? filtered : filtered.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .name:
            topLevel = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        var rows: [ManagerItem] = []
        for item in topLevel {
            rows.append(item)
            if item.isExpandable, expandedIDs.contains(item.id) {
                rows.append(contentsOf: item.children)
            }
        }
        displayedItems = rows
        displayedToken = ManagerItemTable.contentToken(items: rows, sort: sort.rawValue, search: search)
    }

    /// Toggle a top-level row's disclosure and rebuild the visible list.
    private func toggleExpand(_ id: String) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        refreshDisplayedItems()
    }

    // MARK: - Selection sync

    private func syncSelection() {
        if selectedSectionID == nil {
            // Deep-link target (from a dashboard card's Review) if it exists,
            // else the first section.
            let target = initialSectionID.flatMap { id in loadedSections.first { $0.id == id }?.id }
            selectedSectionID = target ?? loadedSections.first?.id
        }
        // Honor a deep-link category when it lives in the selected section,
        // otherwise fall back to that section's first category.
        if let initialCategoryID, sortedCategories.contains(where: { $0.id == initialCategoryID }) {
            selectedCategoryID = initialCategoryID
        } else {
            selectFirstCategory()
        }
    }

    private func selectFirstCategory() {
        selectedCategoryID = sortedCategories.first?.id
    }

    private func icon(_ systemImage: String, _ color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
    }

    /// The visible category's bulk-selection state, driving both the menu's
    /// trigger label and the Select All / Deselect All disabled states.
    private enum BulkSelectionState {
        case none, some, all

        var label: String {
            switch self {
            case .none:
                return String(localized: "None", comment: "Bulk-select trigger when nothing in the category is selected.")
            case .all:
                return String(localized: "All", comment: "Bulk-select trigger when everything in the category is selected.")
            case .some:
                return String(localized: "Some", comment: "Bulk-select trigger when part of the category is selected.")
            }
        }
    }

    /// Resolve the bulk-select state for `category`. Prefers the caller's O(1)
    /// `categorySelectionTally` (leaf-level selected/total counts) when supplied;
    /// otherwise falls back to a per-row `isSelected` scan over the visible
    /// `rows` — fine for the small flat managers that don't provide a tally.
    private func bulkSelectionState(category: ManagerCategory, rows: [ManagerItem]) -> BulkSelectionState {
        if let tally = categorySelectionTally(category) {
            if tally.selected == 0 { return .none }
            if tally.total > 0 && tally.selected >= tally.total { return .all }
            return .some
        }
        let selectedCount = rows.reduce(0) { $0 + (isSelected($1.id) ? 1 : 0) }
        if selectedCount == 0 || rows.isEmpty { return .none }
        if selectedCount == rows.count { return .all }
        return .some
    }
}
