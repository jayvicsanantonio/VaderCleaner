// ScanResult.swift
// Aggregator that groups ScannedFile records by category and reports total/per-category byte counts to the UI.

import Foundation

/// Read-only aggregation of a scan run. Total size and category groupings are
/// computed once during init and stored as constants — UI bindings can read
/// them as many times as they like without re-walking `items`. Pure data:
/// constructing a `ScanResult` never touches disk.
///
/// The view layer binds to `formattedTotalSize` / `sizeByCategory` so the
/// formatting logic lives here, not in every feature view.
struct ScanResult: Equatable {

    /// Files emitted by the scanner. Order is preserved so callers that care
    /// (e.g. Large & Old Files sorting by size descending) can pre-sort
    /// before constructing the result.
    let items: [ScannedFile]

    /// Sum of every item's byte count. `Int64` so values up to 8 EB are
    /// representable without overflow — well past any plausible scan target.
    let totalSize: Int64

    /// Items grouped by their `ScanCategory`. Categories with no matching
    /// items are absent from the dictionary (rather than mapped to an empty
    /// array) so callers can iterate `keys` to learn which categories were
    /// non-empty.
    let itemsByCategory: [ScanCategory: [ScannedFile]]

    /// Total byte count per category. Built in lockstep with
    /// `itemsByCategory` so the two can never disagree.
    let sizeByCategory: [ScanCategory: Int64]

    /// Shared `ByteCountFormatter`. Construction is comparatively expensive
    /// and the formatter is stateless for our use case, so we pay that cost
    /// once for the lifetime of the process.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        return formatter
    }()

    init(items: [ScannedFile]) {
        var total: Int64 = 0
        var grouped: [ScanCategory: [ScannedFile]] = [:]
        var sizes: [ScanCategory: Int64] = [:]
        for item in items {
            total += item.size
            grouped[item.category, default: []].append(item)
            sizes[item.category, default: 0] += item.size
        }
        self.items = items
        self.totalSize = total
        self.itemsByCategory = grouped
        self.sizeByCategory = sizes
    }

    /// Human-readable total ("1.5 KB", "2.3 GB", etc.). Uses
    /// `ByteCountFormatter`'s file-size style so labels match how Finder
    /// reports sizes — which is what users compare scan output to.
    var formattedTotalSize: String {
        Self.byteFormatter.string(fromByteCount: totalSize)
    }
}
