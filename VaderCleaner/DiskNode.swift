// DiskNode.swift
// Reference-typed tree node carrying URL, name, byte size, directory flag, accessibility, and children for the Space Lens disk visualization.

import Foundation

/// One node in the disk-tree built by `DiskScanner`. Reference type because
/// the treemap UI navigates the same node graph from multiple places
/// (breadcrumb stack + currently-rendered tile) and needs identity-based
/// equality so a re-render doesn't consider two snapshots of the "same"
/// node distinct.
///
/// The node holds no I/O machinery — all enumeration happens in
/// `DiskScanner` and the result is fixed once a scan finishes, so every
/// stored property is `let` and the tree is observation-free. A Space Lens
/// scan can instantiate thousands of nodes; opting into per-instance change
/// tracking would tax every tile draw without buying anything because no
/// view ever mutates a node.
///
/// `size` is always pre-rolled-up by the scanner: a directory's value is
/// the sum of its descendants. The treemap relies on this so it can size
/// each tile from a single property read.
final class DiskNode: Identifiable {

    /// Stable identity for SwiftUI diffing. Generated per node so two
    /// scans of the same path produce different IDs — the UI treats them
    /// as fresh trees, which matches the user's mental model of a "rescan".
    let id: UUID

    /// Absolute file URL this node represents. Kept so right-click "Show
    /// in Finder" actions in the upcoming UI can hand the URL to
    /// `NSWorkspace`.
    let url: URL

    /// `lastPathComponent`-style display name. Stored separately so the
    /// scanner can supply a friendlier name for volume roots (e.g.
    /// "Macintosh HD" instead of "/").
    let name: String

    /// Bytes occupied. For directories, this is the sum of all
    /// descendants. For files, the on-disk size returned by
    /// `URLResourceValues.fileSize`. Inaccessible directories report 0
    /// because we never enumerated them.
    let size: Int64

    let isDirectory: Bool

    let children: [DiskNode]

    /// `false` when the scanner could not enumerate this node's contents
    /// (typically permission denied). Lets the UI render a "locked"
    /// affordance instead of pretending the directory is empty.
    let isAccessible: Bool

    /// Number of descendants beneath this node — every file and subfolder,
    /// counted recursively. A leaf file has no descendants, so its own value
    /// is 0; a directory counts each child as `1 + the child's itemCount`.
    /// Pre-rolled by the scanner so the list ("N items") and the
    /// selected-items counter read it from a single property.
    let itemCount: Int

    /// Last content-modification date, or `nil` when the scanner couldn't read
    /// it. Surfaced in the Space Lens hover card's "Modified: …" line.
    let modificationDate: Date?

    init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        size: Int64,
        isDirectory: Bool,
        children: [DiskNode],
        isAccessible: Bool = true,
        itemCount: Int = 0,
        modificationDate: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.children = children
        self.isAccessible = isAccessible
        self.itemCount = itemCount
        self.modificationDate = modificationDate
    }

    /// A copy of this subtree with every node whose `id` is in `ids` removed,
    /// and each surviving ancestor's `size` and `itemCount` recomputed from the
    /// children that remain. Lets Space Lens reflect a Trash removal without
    /// re-walking the volume.
    ///
    /// Survivors keep their original `id` (and modification date) so the
    /// breadcrumb path can be remapped onto the pruned tree. A node never
    /// removes *itself* here — a parent drops a matching child before
    /// recursing — so calling this on the root keeps the root and prunes only
    /// its descendants. Returns `self` unchanged when nothing in `ids` is
    /// present, so the no-op path allocates nothing.
    func removing(_ ids: Set<UUID>) -> DiskNode {
        guard !ids.isEmpty, isDirectory, !children.isEmpty else { return self }

        var newChildren: [DiskNode] = []
        newChildren.reserveCapacity(children.count)
        var changed = false
        for child in children {
            if ids.contains(child.id) {
                changed = true
                continue
            }
            let prunedChild = child.removing(ids)
            if prunedChild !== child { changed = true }
            newChildren.append(prunedChild)
        }
        guard changed else { return self }

        let rolledUpSize = newChildren.reduce(Int64(0)) { $0 + $1.size }
        let rolledUpCount = newChildren.reduce(0) { $0 + 1 + $1.itemCount }
        return DiskNode(
            id: id,
            url: url,
            name: name,
            size: rolledUpSize,
            isDirectory: isDirectory,
            children: newChildren,
            isAccessible: isAccessible,
            itemCount: rolledUpCount,
            modificationDate: modificationDate
        )
    }

    /// Shared, pre-configured formatter so each `formattedSize` access
    /// doesn't pay a fresh `ByteCountFormatter` allocation. The treemap
    /// in Prompt 17 will call this on every visible tile and tooltip,
    /// often hundreds of times per render — `ByteCountFormatter` is
    /// thread-safe for `string(fromByteCount:)` reads, so a single
    /// instance is the right shape.
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .binary
        return formatter
    }()

    /// Pretty-printed byte count for status labels and tile tooltips.
    /// `.useAll` lets the formatter pick the most readable unit for any
    /// magnitude, which is what users expect from a finder-like view.
    var formattedSize: String {
        Self.sizeFormatter.string(fromByteCount: size)
    }

    /// This node's share of `parent` as a value in `[0, 1]`. Returns 0
    /// when the parent reports zero bytes — empty directories hit that
    /// path naturally and would otherwise produce a NaN that crashes the
    /// treemap layout.
    func percentOfParent(_ parent: DiskNode) -> Double {
        guard parent.size > 0 else { return 0 }
        return Double(size) / Double(parent.size)
    }
}
