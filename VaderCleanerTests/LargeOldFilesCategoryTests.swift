// LargeOldFilesCategoryTests.swift
// Tests the pure grouping that turns a flat scan into the dashboard's category tiles — extension/age classification, the top-by-size "Largest" lens, and tile assembly (non-empty only, hero first, correct totals).

import XCTest
@testable import VaderCleaner

final class LargeOldFilesCategoryTests: XCTestCase {

    /// A fixed "now" so the age-based classification is deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Per-category membership

    /// Video extensions land in `.videos`, case-insensitively.
    func test_files_videosMatchVideoExtensions() {
        let files = [
            makeFile(name: "clip.MOV", size: 10),
            makeFile(name: "movie.mkv", size: 10),
            makeFile(name: "notes.txt", size: 10)
        ]
        let videos = LargeOldFilesCategorizer.files(in: .videos, from: files, referenceDate: now)
        XCTAssertEqual(Set(videos.map(\.url.lastPathComponent)), ["clip.MOV", "movie.mkv"])
    }

    /// Installer disk images and compressed archives land in `.archives`. The
    /// sparse VM/container disk images (`.raw`/`.sparsebundle`) are deliberately
    /// excluded — the scanner skips them, and a stray camera `.raw` is "Other".
    func test_files_archivesMatchArchiveExtensions() {
        let files = [
            makeFile(name: "Install.dmg", size: 10),
            makeFile(name: "backup.zip", size: 10),
            makeFile(name: "image.iso", size: 10),
            makeFile(name: "photo.raw", size: 10),
            makeFile(name: "clip.mov", size: 10)
        ]
        let archives = LargeOldFilesCategorizer.files(in: .archives, from: files, referenceDate: now)
        XCTAssertEqual(Set(archives.map(\.url.lastPathComponent)), ["Install.dmg", "backup.zip", "image.iso"])

        // A bare `.raw` is not an archive — it falls through to "Other".
        let other = LargeOldFilesCategorizer.files(in: .other, from: files, referenceDate: now)
        XCTAssertTrue(other.contains { $0.url.lastPathComponent == "photo.raw" })
    }

    /// Anything that is neither a video nor an archive lands in `.other`.
    func test_files_otherExcludesVideosAndArchives() {
        let files = [
            makeFile(name: "clip.mov", size: 10),
            makeFile(name: "backup.zip", size: 10),
            makeFile(name: "report.pdf", size: 10),
            makeFile(name: "README", size: 10)
        ]
        let other = LargeOldFilesCategorizer.files(in: .other, from: files, referenceDate: now)
        XCTAssertEqual(Set(other.map(\.url.lastPathComponent)), ["report.pdf", "README"])
    }

    /// `.old` is age-driven: files last accessed on or before the six-month
    /// cutoff qualify; recently-accessed files and files with no access date
    /// do not.
    func test_files_oldUsesAccessDateCutoff() {
        let ancient = makeFile(name: "ancient.bin", size: 10,
                               accessed: now.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds - 86_400))
        let recent = makeFile(name: "recent.bin", size: 10,
                              accessed: now.addingTimeInterval(-86_400))
        let undated = ScannedFile(url: URL(fileURLWithPath: "/tmp/cat/undated.bin"),
                                  size: 10, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)

        let old = LargeOldFilesCategorizer.files(in: .old, from: [ancient, recent, undated], referenceDate: now)
        XCTAssertEqual(old.map(\.url.lastPathComponent), ["ancient.bin"])
    }

    /// `.largest` is a lens, not a partition: it returns the top N files by
    /// size regardless of type.
    func test_files_largestReturnsTopBySize() {
        let files = (1...(LargeOldFilesCategorizer.largestTileLimit + 5)).map {
            makeFile(name: "f\($0).bin", size: Int64($0))
        }
        let largest = LargeOldFilesCategorizer.files(in: .largest, from: files, referenceDate: now)
        XCTAssertEqual(largest.count, LargeOldFilesCategorizer.largestTileLimit)
        XCTAssertEqual(largest.first?.size, Int64(LargeOldFilesCategorizer.largestTileLimit + 5),
                       "Largest must lead with the biggest file")
    }

    // MARK: - Tile assembly

    /// Categories with no files produce no tile — the grid only shows lenses
    /// that have findings, like the Applications dashboard.
    func test_tiles_omitsEmptyCategories() {
        let files = [makeFile(name: "report.pdf", size: 10)]  // only `.other`
        let categories = LargeOldFilesCategorizer.tiles(from: files, referenceDate: now).map(\.category)
        XCTAssertEqual(categories, [.other])
    }

    /// Among the primary (type/age) tiles, the one with the most reclaimable
    /// bytes is first so the dashboard can promote it to the hero card.
    func test_tiles_heroIsLargestByBytes() {
        let files = [
            makeFile(name: "small.zip", size: 100),          // archives
            makeFile(name: "big.mov", size: 10_000),         // videos
            makeFile(name: "report.pdf", size: 500)          // other
        ]
        let tiles = LargeOldFilesCategorizer.tiles(from: files, referenceDate: now)
        XCTAssertEqual(tiles.first?.category, .videos)
    }

    /// The "Largest Files" lens only earns a tile when there are more files
    /// than it caps at — otherwise it just duplicates the whole result set.
    func test_tiles_largestAppearsOnlyAboveLimit() {
        let few = (1...3).map { makeFile(name: "f\($0).pdf", size: Int64($0)) }
        XCTAssertFalse(LargeOldFilesCategorizer.tiles(from: few, referenceDate: now).contains { $0.category == .largest })

        let many = (1...(LargeOldFilesCategorizer.largestTileLimit + 1)).map {
            makeFile(name: "f\($0).pdf", size: Int64($0))
        }
        XCTAssertTrue(LargeOldFilesCategorizer.tiles(from: many, referenceDate: now).contains { $0.category == .largest })
    }

    /// A tile reports the count, summed size, and old-file count of its files —
    /// all computed once at construction, not derived on access.
    func test_tile_countTotalBytesAndOldCount() {
        let files = [
            makeFile(name: "a.mov", size: 1_000, category: .largeFile),
            makeFile(name: "b.mov", size: 2_500, category: .oldFile)
        ]
        let videos = LargeOldFilesCategorizer.tiles(from: files, referenceDate: now).first { $0.category == .videos }
        XCTAssertEqual(videos?.count, 2)
        XCTAssertEqual(videos?.totalBytes, 3_500)
        XCTAssertEqual(videos?.oldCount, 1)
    }

    // MARK: - Helpers

    private func makeFile(name: String, size: Int64, accessed: Date? = nil, category: ScanCategory = .largeFile) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/cat/\(name)"),
            size: size,
            lastAccessDate: accessed,
            lastModifiedDate: accessed,
            category: category
        )
    }
}
