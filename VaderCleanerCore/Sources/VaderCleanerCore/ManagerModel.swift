// ManagerModel.swift
// The Sendable data model every Smart Scan Manager screen renders — sections, categories, items, row tints, selection totals, byte text, and sort order. Built off the main actor so opening a manager over tens of thousands of files never blocks the UI.

import Foundation

/// Icon tint for a manager row. A plain `Sendable` enum (rather than a SwiftUI
/// `Color`) so the whole item model can be built off the main actor; the view
/// maps it to a `Color` at render time.
public enum ManagerTint: Sendable, Hashable {
    case green, blue, red, orange, purple, secondary
}

/// One selectable leaf row in the manager's right-hand pane. Fully `Sendable`
/// with a precomputed `sizeText` so building and scrolling never touch a
/// `ByteCountFormatter` (which is slow per-row and stutters large lists).
public struct ManagerItem: Identifiable, Hashable, Sendable {
    /// Stable selection key (e.g. a file URL's path or a bundle id).
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Byte size, when the item has one. Used for sorting; `nil` for items not
    /// measured in bytes (e.g. app updates).
    public let size: Int64?
    /// Pre-rendered size string, or `nil` for sizeless items.
    public let sizeText: String?
    public let systemImage: String
    public let tint: ManagerTint
    /// When true the row shows the real Finder icon for the file at `id` (a file
    /// path) instead of `systemImage` — used by the Cleanup Manager so app and
    /// document rows look like Finder. Other managers leave this off and keep
    /// their tinted SF Symbol.
    public var usesFileIcon: Bool = false
    /// When true the row draws a Quick Look thumbnail of the file at `id` (or
    /// `iconPath`) instead of a Finder icon or tinted symbol — so the image
    /// managers (Similar Photos, and the photo side of Duplicates) show the
    /// actual picture the user is deciding on. Loaded async and cached.
    public var usesThumbnail: Bool = false
    /// When true the row is shown for context but can't be selected: it has no
    /// checkbox and carries a "Kept" marker. Used for the best shot a
    /// similar-photo group keeps, so the user can see what survives without
    /// being able to delete it.
    public var isLocked: Bool = false
    /// Filesystem path the Finder icon is drawn from when `usesFileIcon` is set
    /// and the row's selection `id` is *not* itself a path (e.g. a login item
    /// keyed by bundle id, or a launch agent whose app bundle differs from its
    /// plist). `nil` falls back to `id`.
    public var iconPath: String? = nil
    /// Immediate children revealed when this row is expanded (one level only).
    /// Empty for leaf rows and for managers that don't show a tree.
    public var children: [ManagerItem] = []
    /// Indentation depth: 0 for a top-level row, 1 for an expanded child.
    public var indentLevel: Int = 0
    /// Leaf file paths this row covers, for aggregate folder selection. A leaf
    /// file is `[its path]`; a folder is every scanned file beneath it. Empty
    /// for managers whose selection is keyed directly by `id`.
    var selectionPaths: [String] = []

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(
        id: String,
        title: String,
        subtitle: String?,
        size: Int64?,
        sizeText: String?,
        systemImage: String,
        tint: ManagerTint,
        usesFileIcon: Bool = false,
        usesThumbnail: Bool = false,
        isLocked: Bool = false,
        iconPath: String? = nil,
        children: [ManagerItem] = [],
        indentLevel: Int = 0,
        selectionPaths: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.size = size
        self.sizeText = sizeText
        self.systemImage = systemImage
        self.tint = tint
        self.usesFileIcon = usesFileIcon
        self.usesThumbnail = usesThumbnail
        self.isLocked = isLocked
        self.iconPath = iconPath
        self.children = children
        self.indentLevel = indentLevel
        self.selectionPaths = selectionPaths
    }

    /// Whether this row has children to disclose.
    public var isExpandable: Bool { !children.isEmpty }
}

/// One extra entry in a category's "Select:" menu, below Select All / Deselect
/// All. Hosts supply the category-specific picks (the Cleanup Manager's idle
/// projects filter); the manager only renders them and calls `apply`.
public struct ManagerSelectFilter: Identifiable {
    public let id: String
    public let title: String
    public let apply: () -> Void
}

/// A group of items shown in the manager's middle pane. Its items are stored
/// pre-sorted by size (descending) by the builder, so the default view needs no
/// main-thread sort.
public struct ManagerCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let tint: ManagerTint
    /// Asset-catalog name of the glossy 3D badge shown for the category. When
    /// `nil` the row falls back to the tinted `systemImage`. The Cleanup Manager
    /// sets this so its categories match the dashboard's badge artwork.
    public var badgeAsset: String? = nil
    public let items: [ManagerItem]
    /// Sum of the category's item sizes, or `nil` when its items carry no size.
    public let totalSize: Int64?
    /// Pre-rendered total size string for the badge, or `nil`.
    public let totalSizeText: String?
    /// One-line explanation shown as the right pane's header when this category
    /// is selected. `nil` hides the header.
    public var description: String? = nil

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(
        id: String,
        title: String,
        systemImage: String,
        tint: ManagerTint,
        badgeAsset: String? = nil,
        items: [ManagerItem],
        totalSize: Int64?,
        totalSizeText: String?,
        description: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.badgeAsset = badgeAsset
        self.items = items
        self.totalSize = totalSize
        self.totalSizeText = totalSizeText
        self.description = description
    }
}

/// A top-level grouping shown in the manager's left pane (e.g. "System Junk",
/// "Mail Attachments", "Trash").
public struct ManagerSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let categories: [ManagerCategory]
    /// One-line explanation shown as the middle pane's header when this section
    /// is selected. `nil` hides the header.
    public var description: String? = nil

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(id: String, title: String, categories: [ManagerCategory], description: String? = nil) {
        self.id = id
        self.title = title
        self.categories = categories
        self.description = description
    }
}

/// Pre-tallied selection totals for the footer, so it doesn't have to scan
/// every item on each render. `bytes` is `nil` for tiles whose items carry no
/// size (e.g. app updates, threats).
public struct ManagerSelectionSummary {
    public let count: Int
    public let bytes: Int64?

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(count: Int, bytes: Int64?) {
        self.count = count
        self.bytes = bytes
    }
}

/// Fast, thread-safe byte formatter for the high-volume manager rows.
/// `ByteCountFormatter` is too slow to call per row (it stutters scrolling) and
/// isn't safe to share across threads; this approximates its file-style output
/// (1000-based units) cheaply so sizes can be precomputed off the main actor.
public enum ManagerByteText {
    public static func string(_ bytes: Int64) -> String {
        if bytes < 1000 {
            return String.localizedStringWithFormat(
                String(localized: "%lld bytes", bundle: .module, comment: "Byte count under 1 KB in a Smart Scan Manager row."),
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
public enum ManagerSort: String, CaseIterable, Identifiable {
    case size
    case name
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .size:
            return String(localized: "Size", bundle: .module, comment: "Manager sort option ordering by byte size, largest first.")
        case .name:
            return String(localized: "Name", bundle: .module, comment: "Manager sort option ordering alphabetically by name.")
        }
    }
}
