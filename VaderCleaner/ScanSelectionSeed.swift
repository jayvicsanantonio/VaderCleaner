// ScanSelectionSeed.swift
// Precomputed junk-selection state (URLs plus running byte/count tallies) built from a scan result off the main actor, so seeding a large result never stalls the UI.

import Foundation

/// The selection state a fresh `ScanResult` seeds into a junk view model: the
/// selected URLs plus the running per-category tallies the Cleanup Manager
/// reads in O(1).
///
/// The builders are `nonisolated` and `async` so a main-actor caller hops off
/// the main thread for the walk. Hashing every URL of a large scan into a
/// `Set` costs seconds — each bridged `URL` hash/equality round-trips through
/// its Cocoa `relativeString` — and doing that walk on the main thread froze
/// the scan-complete transition for the whole duration (a measured 3.2 s
/// severe hang on a ~120 GB junk result).
struct ScanSelectionSeed: Equatable, Sendable {
    var urls: Set<URL> = []
    var totalBytes: Int64 = 0
    var bytesByCategory: [ScanCategory: Int64] = [:]
    var countByCategory: [ScanCategory: Int] = [:]

    /// Safe-by-default seed: every file in a regenerable / already-discarded
    /// category is selected; user-data categories stay opt-in. The same rule
    /// `SystemJunkViewModel.scan()` and Smart Scan apply, kept in one place so
    /// the seeded surfaces can never disagree.
    static func safeDefaults(from result: ScanResult) async -> ScanSelectionSeed {
        build(from: result) { $0.isSafeToAutoRemove }
    }

    /// Seed covering exactly `categories` — backs a dashboard card's Review,
    /// which opens the manager with that card's whole group pre-selected so
    /// the selected total matches the card's displayed size.
    static func selection(
        of categories: Set<ScanCategory>,
        from result: ScanResult
    ) async -> ScanSelectionSeed {
        build(from: result) { categories.contains($0) }
    }

    /// Single-pass builder over the result's precomputed category groupings.
    /// Per-category byte totals come straight from `sizeByCategory`, so the
    /// only per-file work is the URL set insertion.
    private static func build(
        from result: ScanResult,
        including: (ScanCategory) -> Bool
    ) -> ScanSelectionSeed {
        var seed = ScanSelectionSeed()
        let included = result.itemsByCategory.filter { including($0.key) }
        seed.urls.reserveCapacity(included.values.reduce(0) { $0 + $1.count })
        for (category, files) in included {
            seed.urls.formUnion(files.lazy.map(\.url))
            let bytes = result.sizeByCategory[category] ?? 0
            seed.totalBytes += bytes
            seed.bytesByCategory[category] = bytes
            seed.countByCategory[category] = files.count
        }
        return seed
    }
}
