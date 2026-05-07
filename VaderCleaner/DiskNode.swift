// DiskNode.swift
// Reference-typed tree node carrying URL, name, byte size, directory flag, accessibility, and children for the Space Lens disk visualization.

import Foundation

/// One node in the disk-tree built by `DiskScanner`. Reference type because
/// the treemap UI in Prompt 17 navigates the same node graph from multiple
/// places (breadcrumb stack + currently-rendered tile) and needs identity-
/// based equality so a re-render doesn't consider two snapshots of the
/// "same" node distinct.
///
/// The node holds no I/O machinery — all enumeration happens in
/// `DiskScanner` and the result is fixed once a scan finishes. The class
/// adopts `ObservableObject` so future incremental-scan work (Prompt 17 may
/// add live-update during a long scan) can republish without touching the
/// public API.
///
/// `size` is always pre-rolled-up by the scanner: a directory's value is
/// the sum of its descendants. The treemap relies on this so it can size
/// each tile from a single property read.
final class DiskNode: Identifiable, ObservableObject {

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

    init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        size: Int64,
        isDirectory: Bool,
        children: [DiskNode],
        isAccessible: Bool = true
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.children = children
        self.isAccessible = isAccessible
    }

    /// Pretty-printed byte count for status labels and tile tooltips.
    /// `.useAll` lets the formatter pick the most readable unit for any
    /// magnitude, which is what users expect from a finder-like view.
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: size)
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
