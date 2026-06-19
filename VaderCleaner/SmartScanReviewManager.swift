// SmartScanReviewManager.swift
// Reusable three-pane "Manager" shell for every Smart Scan Review screen — sections list, category list with size badges, and a per-item checkbox list, with search, sort, and a live selected-count footer.

import SwiftUI

/// One selectable leaf row in the manager's right-hand pane.
struct ManagerItem: Identifiable, Hashable {
    /// Stable selection key (e.g. a file URL's path or a bundle id).
    let id: String
    let title: String
    let subtitle: String?
    /// Byte size, when the item has one. Drives the row's trailing size text
    /// and the footer's total. `nil` for items that aren't measured in bytes
    /// (e.g. app updates).
    let size: Int64?
    let systemImage: String
    let iconColor: Color
}

/// A group of items shown in the manager's middle pane, with its own icon and
/// aggregate size badge.
struct ManagerCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let iconColor: Color
    let items: [ManagerItem]

    /// Sum of the category's item sizes, or `nil` when its items carry no size.
    var totalSize: Int64? {
        let sizes = items.compactMap(\.size)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// A top-level grouping shown in the manager's left pane (e.g. "System Junk",
/// "Mail Attachments", "Trash").
struct ManagerSection: Identifiable, Hashable {
    let id: String
    let title: String
    let categories: [ManagerCategory]
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

/// Reusable three-pane Cleanup-Manager-style Review shell. Selection is owned by
/// the caller (the view model); the manager reads it through `isSelected` and
/// drives it through `onToggle` / `onSetCategory`, so it stays stateless about
/// what "selected" means for each tile.
struct SmartScanReviewManager: View {
    let title: String
    let sections: [ManagerSection]
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
    /// item count instead of a selected-count. Used by the Performance Manager,
    /// whose login items are informational (Run executes maintenance scripts,
    /// not a per-item selection).
    var showsSelection: Bool = true
    /// Optional secondary footer button shown left of "Done" — e.g. the
    /// Performance Manager's "Open Optimization" jump-link.
    var secondaryActionTitle: String? = nil
    var onSecondaryAction: (() -> Void)? = nil

    @State private var selectedSectionID: String?
    @State private var selectedCategoryID: String?
    @State private var search = ""
    @State private var sort: ManagerSort = .size

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                sectionPane
                Divider().opacity(0.4)
                categoryPane
                Divider().opacity(0.4)
                itemPane
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(accessibilityPrefix)
        .onAppear { syncSelection() }
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
        List(sections, selection: $selectedSectionID) { section in
            Text(section.title)
                .font(.body.weight(.medium))
                .tag(section.id)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 200)
        .onChange(of: selectedSectionID) { _, _ in selectFirstCategory() }
    }

    private var categoryPane: some View {
        List(sortedCategories, selection: $selectedCategoryID) { category in
            HStack(spacing: 12) {
                icon(category.systemImage, category.iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.body.weight(.medium))
                    if let total = category.totalSize {
                        Text(smartScanByteFormatter.string(fromByteCount: total))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(category.items.count) item\(category.items.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let total = category.totalSize {
                    Text(smartScanByteFormatter.string(fromByteCount: total))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
            }
            .padding(.vertical, 4)
            .tag(category.id)
            .accessibilityIdentifier("\(accessibilityPrefix).category.\(category.id)")
        }
        .scrollContentBackground(.hidden)
        .frame(width: 320)
    }

    private var itemPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let category = selectedCategory {
                if showsSelection {
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

                List(sortedItems(in: category)) { item in
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
            icon(item.systemImage, item.iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let size = item.size {
                Text(smartScanByteFormatter.string(fromByteCount: size))
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
            let total = sections.reduce(0) { $0 + $1.categories.reduce(0) { $0 + $1.items.count } }
            return String.localizedStringWithFormat(
                String(localized: "%lld items", comment: "Plain item count in a read-only Smart Scan Manager footer."),
                total
            )
        }
        var count = 0
        var bytes: Int64 = 0
        var hasSized = false
        for section in sections {
            for category in section.categories {
                for item in category.items where isSelected(item.id) {
                    count += 1
                    if let size = item.size { bytes += size; hasSized = true }
                }
            }
        }
        let countText = String.localizedStringWithFormat(
            String(localized: "%lld Items Selected", comment: "Live count of selected items in a Smart Scan Manager footer."),
            count
        )
        guard hasSized else { return countText }
        return "\(countText)  ·  \(smartScanByteFormatter.string(fromByteCount: bytes))"
    }

    // MARK: - Derived data

    private var selectedSection: ManagerSection? {
        sections.first { $0.id == selectedSectionID } ?? sections.first
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

    private func sortedItems(in category: ManagerCategory) -> [ManagerItem] {
        let filtered = search.isEmpty
            ? category.items
            : category.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .size:
            return filtered.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .name:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: - Selection sync

    /// Seed the section/category selection on first appearance so the panes
    /// open on real content rather than blank.
    private func syncSelection() {
        if selectedSectionID == nil { selectedSectionID = sections.first?.id }
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
