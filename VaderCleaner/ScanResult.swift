// ScanResult.swift
// Aggregator that groups ScannedFile records by category and reports total/per-category byte counts to the UI.

import Foundation

/// Read-only aggregation of a scan run. Computes total size and category
/// groupings lazily from the `items` array. Pure data — constructing a
/// `ScanResult` never touches disk.
///
/// The view layer binds to `formattedTotalSize` / `sizeByCategory` so the
/// formatting logic lives here, not in every feature view.
struct ScanResult: Equatable {

    /// Files emitted by the scanner. Order is preserved so callers that care
    /// (e.g. Large & Old Files sorting by size descending) can pre-sort
    /// before constructing the result.
    let items: [ScannedFile]

    init(items: [ScannedFile]) {
        self.items = items
    }

    /// Sum of every item's byte count. `Int64` so values up to 8 EB are
    /// representable without overflow — well past any plausible scan target.
    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    /// Items grouped by their `ScanCategory`. Categories with no matching
    /// items are absent from the dictionary (rather than mapped to an empty
    /// array) so callers can iterate `keys` to learn which categories were
    /// non-empty.
    var itemsByCategory: [ScanCategory: [ScannedFile]] {
        Dictionary(grouping: items, by: \.category)
    }

    /// Total byte count per category. Built from `itemsByCategory` so the two
    /// can never disagree.
    var sizeByCategory: [ScanCategory: Int64] {
        itemsByCategory.mapValues { files in
            files.reduce(0) { $0 + $1.size }
        }
    }

    /// Human-readable total ("1.5 KB", "2.3 GB", etc.). Uses
    /// `ByteCountFormatter`'s file-size style so labels match how Finder
    /// reports sizes — which is what users compare scan output to.
    var formattedTotalSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}
