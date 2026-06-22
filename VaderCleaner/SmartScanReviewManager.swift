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
}

/// A top-level grouping shown in the manager's left pane (e.g. "System Junk",
/// "Mail Attachments", "Trash").
struct ManagerSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let categories: [ManagerCategory]
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
            refreshDisplayedItems()
        }
        .onChange(of: sort) { _, _ in refreshDisplayedItems() }
        .onChange(of: search) { _, _ in refreshDisplayedItems() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
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
                    .foregroundStyle(.secondary)
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
                    navRow(selected: section.id == selectedSection?.id) {
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
        ScrollView {
            VStack(spacing: 4) {
                ForEach(sortedCategories) { category in
                    navRow(selected: category.id == selectedCategory?.id) {
                        selectedCategoryID = category.id
                    } content: {
                        categoryRow(category)
                    }
                    .accessibilityIdentifier("\(accessibilityPrefix).category.\(category.id)")
                }
            }
            .padding(8)
        }
        .frame(width: 200)
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
                Text(category.title).font(.body.weight(.medium))
                if let text = category.totalSizeText {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(category.items.count) item\(category.items.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
    }

    /// A selectable nav row in the section/category panes, tinted with the
    /// section accent when selected so it reads as part of the app's glow
    /// language instead of the grey system list highlight.
    private func navRow<Content: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? accent.opacity(0.22) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? accent.opacity(0.40) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var itemPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedCategory != nil {
                if showsSelection, let category = selectedCategory {
                    let selectedCount = category.items.reduce(0) { $0 + (isSelected($1.id) ? 1 : 0) }
                    HStack(spacing: 8) {
                        Text(String(localized: "Select:", comment: "Label before the bulk-select menu on a Smart Scan Manager."))
                            .foregroundStyle(.secondary)
                        Menu {
                            Button(String(localized: "Smartly", comment: "Bulk-select the recommended items in the category.")) {
                                onSetCategory(category, true)
                            }
                            Button(String(localized: "Select All", comment: "Bulk-select every item in the category.")) {
                                onSetCategory(category, true)
                            }
                            .disabled(selectedCount == category.items.count)
                            Button(String(localized: "Deselect All", comment: "Bulk-deselect every item in the category.")) {
                                onSetCategory(category, false)
                            }
                            .disabled(selectedCount == 0)
                        } label: {
                            Text(bulkSelectLabel(selected: selectedCount, total: category.items.count))
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

                ManagerItemTable(
                    items: displayedItems,
                    showsSelection: showsSelection,
                    isSelected: isSelected,
                    onToggle: onToggle,
                    accent: accent,
                    rowHeight: 44,
                    contentToken: "\(selectedCategoryID ?? "")|\(sort.rawValue)|\(search)|\(expandedIDs.sorted().joined(separator: ","))",
                    accessibilityPrefix: accessibilityPrefix,
                    forcesLightAppearance: lightSurface,
                    showsSparkle: showsSparkle,
                    isExpanded: { expandedIDs.contains($0) },
                    onToggleExpand: { toggleExpand($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Text(String(localized: "Nothing to review", comment: "Empty state in a Smart Scan Manager's detail pane."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
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
        guard let category = selectedCategory else { displayedItems = []; return }
        let filtered = search.isEmpty
            ? category.items
            : category.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
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
    }

    /// Toggle a top-level row's disclosure and rebuild the visible list.
    private func toggleExpand(_ id: String) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        refreshDisplayedItems()
    }

    // MARK: - Selection sync

    private func syncSelection() {
        if selectedSectionID == nil { selectedSectionID = loadedSections.first?.id }
        selectFirstCategory()
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

    /// The bulk-select menu's trigger label, reflecting the visible category's
    /// current selection: "None", "All", or "Some".
    private func bulkSelectLabel(selected: Int, total: Int) -> String {
        if selected == 0 || total == 0 {
            return String(localized: "None", comment: "Bulk-select trigger when nothing in the category is selected.")
        }
        if selected == total {
            return String(localized: "All", comment: "Bulk-select trigger when everything in the category is selected.")
        }
        return String(localized: "Some", comment: "Bulk-select trigger when part of the category is selected.")
    }
}

/// Applies the white, light-mode surface for the standalone Cleanup Manager.
/// A no-op when `light` is false so Smart Scan's managers keep inheriting the
/// section's dark gradient. The `colorScheme` override flips the SwiftUI chrome
/// to dark-on-light; the AppKit item table is switched separately via
/// `ManagerItemTable.forcesLightAppearance`.
private struct ManagerSurfaceModifier: ViewModifier {
    let light: Bool

    func body(content: Content) -> some View {
        if light {
            content
                .environment(\.colorScheme, .light)
                .background(Color.white)
        } else {
            content
        }
    }
}
