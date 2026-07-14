// MyClutterSelectionSeedTests.swift
// Pins MyClutterSelectionSeed's off-main builder: safe-by-default selection of redundant copies plus the size/category read-model the view model applies in O(1).

import XCTest
@testable import VaderCleaner

final class MyClutterSelectionSeedTests: XCTestCase {

    /// Safe-by-default: every redundant duplicate and near-duplicate copy is
    /// pre-selected (deleting one always leaves an original); large/old files
    /// and downloads — real user data — stay unselected.
    func test_safeDefaults_selectsOnlyRedundantCopies() async {
        let dupOriginal = file("/docs/report.pdf", size: 100)
        let dupCopy = file("/docs/report copy.pdf", size: 100)
        let simOriginal = file("/pics/sunset.jpg", size: 50)
        let simCopy = file("/pics/sunset-edit.jpg", size: 40)
        let large = file("/movies/big.mov", size: 9000)
        let download = DownloadItem(file: file("/downloads/tool.dmg", size: 700), sourceApp: nil)

        let seed = await MyClutterSelectionSeed.safeDefaults(
            duplicates: [DuplicateGroup(files: [dupOriginal, dupCopy])],
            similar: [SimilarImageGroup(files: [simOriginal, simCopy])],
            largeOld: [large],
            downloads: [download]
        )

        XCTAssertEqual(seed.selectedURLs, [dupCopy.url, simCopy.url])
        XCTAssertEqual(seed.totalSelectedSize, 140)
    }

    /// The size map must cover every file in every category — the unselected
    /// ones too, so toggling a large/old file later finds its size.
    func test_safeDefaults_sizeAndCategoryMapsCoverAllCategories() async {
        let dupOriginal = file("/docs/a.pdf", size: 10)
        let dupCopy = file("/docs/a copy.pdf", size: 10)
        let large = file("/movies/big.mov", size: 9000)
        let download = DownloadItem(file: file("/downloads/tool.dmg", size: 700), sourceApp: nil)

        let seed = await MyClutterSelectionSeed.safeDefaults(
            duplicates: [DuplicateGroup(files: [dupOriginal, dupCopy])],
            similar: [],
            largeOld: [large],
            downloads: [download]
        )

        XCTAssertEqual(seed.sizeByURL[dupCopy.url], 10)
        XCTAssertEqual(seed.sizeByURL[large.url], 9000)
        XCTAssertEqual(seed.sizeByURL[download.file.url], 700)
        XCTAssertEqual(seed.categoriesByURL[dupCopy.url], [.duplicates])
        XCTAssertEqual(seed.categoriesByURL[large.url], [.largeOld])
        XCTAssertEqual(seed.categoriesByURL[download.file.url], [.downloads])
        XCTAssertNil(seed.sizeByURL[URL(fileURLWithPath: "/not/scanned")])
    }

    /// The per-category selected tallies must match what the manager footer
    /// shows, and a file that is both a duplicate copy and a similar copy is
    /// selected once but tallied in both categories — the same accounting
    /// `recomputeSelectedCategoryTotals()` produces.
    func test_safeDefaults_talliesSharedFilesInEveryMemberCategory() async {
        let dupOriginal = file("/docs/a.pdf", size: 10)
        let shared = file("/docs/shared.jpg", size: 30)
        let simOriginal = file("/pics/base.jpg", size: 20)

        let seed = await MyClutterSelectionSeed.safeDefaults(
            duplicates: [DuplicateGroup(files: [dupOriginal, shared])],
            similar: [SimilarImageGroup(files: [simOriginal, shared])],
            largeOld: [],
            downloads: []
        )

        XCTAssertEqual(seed.selectedURLs, [shared.url], "Shared file selects once")
        XCTAssertEqual(seed.totalSelectedSize, 30, "Shared file's bytes count once in the grand total")
        XCTAssertEqual(seed.categoriesByURL[shared.url], [.duplicates, .similar])
        XCTAssertEqual(seed.selectedBytesByCategory, [.duplicates: 30, .similar: 30])
        XCTAssertEqual(seed.selectedCountByCategory, [.duplicates: 1, .similar: 1])
    }

    /// Empty inputs produce the empty seed — the `.empty` phase's shape.
    func test_safeDefaults_ofNothing_isEmpty() async {
        let seed = await MyClutterSelectionSeed.safeDefaults(
            duplicates: [], similar: [], largeOld: [], downloads: []
        )
        XCTAssertEqual(seed, MyClutterSelectionSeed())
    }

    // MARK: - Helpers

    private func file(_ path: String, size: Int64) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .largeFile
        )
    }
}
