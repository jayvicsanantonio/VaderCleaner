// ManagerModel.swift
// The Sendable data model every Smart Scan Manager screen renders — sections, categories, items, row tints, selection totals, byte text, and sort order. Built off the main actor so opening a manager over tens of thousands of files never blocks the UI.

import Foundation

/// Icon tint for a manager row. A plain `Sendable` enum (rather than a SwiftUI
/// `Color`) so the whole item model can be built off the main actor; the view
/// maps it to a `Color` at render time.
enum ManagerTint: Sendable, Hashable {
    case green, blue, red, orange, purple, secondary
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
    /// When true the row draws a Quick Look thumbnail of the file at `id` (or
    /// `iconPath`) instead of a Finder icon or tinted symbol — so the image
    /// managers (Similar Photos, and the photo side of Duplicates) show the
    /// actual picture the user is deciding on. Loaded async and cached.
    var usesThumbnail: Bool = false
    /// When true the row is shown for context but can't be selected: it has no
    /// checkbox and carries a "Kept" marker. Used for the best shot a
    /// similar-photo group keeps, so the user can see what survives without
    /// being able to delete it.
    var isLocked: Bool = false
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
