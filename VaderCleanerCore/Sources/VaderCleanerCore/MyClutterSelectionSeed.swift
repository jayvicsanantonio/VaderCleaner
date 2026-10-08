// MyClutterSelectionSeed.swift
// Precomputed My Clutter selection state (URLs plus the size/category read-model) built from scan results off the main actor, so seeding a large result never stalls the UI.

import Foundation

/// The state a fresh My Clutter scan seeds into its view model: the
/// safe-by-default selection plus the per-URL size/category maps and the
/// per-category selected tallies the manager reads in O(1).
///
/// The builder is `nonisolated` and `async` so a main-actor caller hops off
/// the main thread for the walk — the same rationale as `ScanSelectionSeed`:
/// hashing every URL of a large result into `Set`/`Dictionary` costs seconds
/// (each bridged `URL` hash round-trips through its Cocoa `relativeString`),
/// and on the main thread that walk freezes the scan-complete transition.
struct MyClutterSelectionSeed: Equatable, Sendable {
    var selectedURLs: Set<URL> = []
    var totalSelectedSize: Int64 = 0
    var selectedBytesByCategory: [MyClutterCategory: Int64] = [:]
    var selectedCountByCategory: [MyClutterCategory: Int] = [:]
    var sizeByURL: [URL: Int64] = [:]
    var categoriesByURL: [URL: [MyClutterCategory]] = [:]

    /// Safe-by-default seed: the redundant duplicate and near-duplicate copies
    /// are pre-selected (deleting one always leaves an original) while the
    /// large/old files and downloads — real user data — stay unselected, so
    /// removing them is an explicit choice. Mirrors Smart Scan and the
    /// app-wide safe-by-default rule (see `ScanCategory.isSafeToAutoRemove`).
    static func safeDefaults(
        duplicates: [DuplicateGroup],
        similar: [SimilarImageGroup],
        largeOld: [ScannedFile],
        downloads: [DownloadItem]
    ) async -> MyClutterSelectionSeed {
        var seed = MyClutterSelectionSeed()

        let duplicateCopies = duplicates.flatMap { $0.redundantCopies }
        let similarCopies = similar.flatMap { $0.redundantCopies }

        // Same insertion order as the view model's prune-path rebuild, so a
        // URL that appears in several categories lands on identical map
        // entries either way.
        for file in duplicateCopies {
            seed.sizeByURL[file.url] = file.size
            seed.categoriesByURL[file.url, default: []].append(.duplicates)
        }
        for file in similarCopies {
            seed.sizeByURL[file.url] = file.size
            seed.categoriesByURL[file.url, default: []].append(.similar)
        }
        for file in largeOld {
            seed.sizeByURL[file.url] = file.size
            seed.categoriesByURL[file.url, default: []].append(.largeOld)
        }
        for item in downloads {
            seed.sizeByURL[item.file.url] = item.file.size
            seed.categoriesByURL[item.file.url, default: []].append(.downloads)
        }

        seed.selectedURLs = Set(duplicateCopies.map(\.url)).union(similarCopies.map(\.url))
        for url in seed.selectedURLs {
            let size = seed.sizeByURL[url] ?? 0
            seed.totalSelectedSize += size
            for category in seed.categoriesByURL[url] ?? [] {
                seed.selectedBytesByCategory[category, default: 0] += size
                seed.selectedCountByCategory[category, default: 0] += 1
            }
        }
        return seed
    }
}
