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
    static func safeDefaults(
        from result: ScanResult,
        cacheRoots: [String] = WebDevArtifact.packageCacheRoots
    ) async -> ScanSelectionSeed {
        build(from: result, cacheRoots: cacheRoots) { $0.isSafeToAutoRemove }
    }

    /// Seed covering exactly `categories` — backs a dashboard card's Review,
    /// which opens the manager with that card's group pre-selected so the
    /// selected total matches the card's displayed size. Project build
    /// artifacts are the one exception (see `isPreselectable`): a card's Review
    /// must not arrive with every project's dependencies already checked.
    static func selection(
        of categories: Set<ScanCategory>,
        from result: ScanResult,
        cacheRoots: [String] = WebDevArtifact.packageCacheRoots
    ) async -> ScanSelectionSeed {
        build(from: result, cacheRoots: cacheRoots) { categories.contains($0) }
    }

    /// Whether a file in an otherwise-safe category may be checked without the
    /// user asking for it.
    ///
    /// Web Development Junk is only half regenerable-at-no-cost. Its package
    /// caches re-download on demand, but a project's `node_modules` costs *that
    /// project* a full reinstall the next time it's opened — a real interruption
    /// to work in progress, not a background refill. So the caches pre-check and
    /// the per-project artifacts stay an explicit choice.
    private static func isPreselectable(_ file: ScannedFile, cacheRoots: [String]) -> Bool {
        guard file.category == .webDevJunk else { return true }
        return !WebDevArtifact.isProjectArtifact(file.url, cacheRoots: cacheRoots)
    }

    /// Single-pass builder over the result's precomputed category groupings.
    /// A category whose files are all pre-selectable takes its byte total
    /// straight from `sizeByCategory`, so the only per-file work is the URL set
    /// insertion; the categories that filter per file sum their own totals.
    private static func build(
        from result: ScanResult,
        cacheRoots: [String],
        including: (ScanCategory) -> Bool
    ) -> ScanSelectionSeed {
        var seed = ScanSelectionSeed()
        let included = result.itemsByCategory.filter { including($0.key) }
        seed.urls.reserveCapacity(included.values.reduce(0) { $0 + $1.count })
        for (category, files) in included {
            let selectable = files.filter { isPreselectable($0, cacheRoots: cacheRoots) }
            guard !selectable.isEmpty else { continue }
            seed.urls.formUnion(selectable.lazy.map(\.url))
            let bytes = selectable.count == files.count
                ? (result.sizeByCategory[category] ?? 0)
                : selectable.reduce(Int64(0)) { $0 + $1.size }
            seed.totalBytes += bytes
            seed.bytesByCategory[category] = bytes
            seed.countByCategory[category] = selectable.count
        }
        return seed
    }
}
