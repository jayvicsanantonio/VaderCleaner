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
}

/// A group of items shown in the manager's middle pane. Its items are stored
/// pre-sorted by size (descending) by the builder, so the default view needs no
/// main-thread sort.
struct ManagerCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let tint: ManagerTint
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
    /// Optional secondary footer button shown left of "Done".
    var secondaryActionTitle: String? = nil
    var onSecondaryAction: (() -> Void)? = nil
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
    /// The filtered + sorted items for the visible category, recomputed only
    /// when the category, sort, or search changes — never on a selection toggle.
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
        .onChange(of: selectedCategoryID) { _, _ in refreshDisplayedItems() }
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
        .frame(width: 320)
    }

    private func categoryRow(_ category: ManagerCategory) -> some View {
        HStack(spacing: 12) {
            icon(category.systemImage, category.tint.color)
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
            if let text = category.totalSizeText {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent.opacity(0.18), in: Capsule())
            }
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
                    HStack(spacing: 8) {
                        Text(String(localized: "Select:", comment: "Label before the bulk-select menu on a Smart Scan Manager."))
                            .foregroundStyle(.secondary)
                        Menu {
                            Button(String(localized: "All", comment: "Bulk-select every item in the category.")) {
                                onSetCategory(category, true)
                            }
                            Button(String(localized: "None", comment: "Bulk-deselect every item in the category.")) {
                                onSetCategory(category, false)
                            }
                        } label: {
                            Text(String(localized: "Smartly", comment: "Default bulk-select mode label on a Smart Scan Manager."))
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

                List(displayedItems) { item in
                    itemRow(item)
                }
                .scrollContentBackground(.hidden)
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

    private func itemRow(_ item: ManagerItem) -> some View {
        HStack(spacing: 12) {
            if showsSelection {
                Toggle("", isOn: Binding(
                    get: { isSelected(item.id) },
                    set: { _ in onToggle(item.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            icon(item.systemImage, item.tint.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let sizeText = item.sizeText {
                Text(sizeText)
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("\(accessibilityPrefix).item.\(item.id)")
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
            Button(String(localized: "Done", comment: "Confirms the Manager selection and returns to the Smart Scan dashboard."), action: onBack)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
        let countText = String.localizedStringWithFormat(
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

    /// Rebuild the visible item list. Called only when the category, sort, or
    /// search changes — never on a selection toggle. The builder pre-sorts each
    /// category by size, so the default view (size, no search) needs no sort.
    private func refreshDisplayedItems() {
        guard let category = selectedCategory else { displayedItems = []; return }
        if search.isEmpty && sort == .size {
            displayedItems = category.items
            return
        }
        let filtered = search.isEmpty
            ? category.items
            : category.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .size:
            displayedItems = filtered.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .name:
            displayedItems = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
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
}
