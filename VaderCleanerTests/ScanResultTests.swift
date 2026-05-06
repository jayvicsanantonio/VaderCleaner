// ScanResultTests.swift
// Tests that ScanResult aggregates ScannedFile records by category and reports a correct total size.

import XCTest
@testable import VaderCleaner

/// Exercises the pure aggregation layer that sits between scanners and the
/// UI. Constructed from a fixed set of `ScannedFile` records so these tests
/// never touch disk — the file system traversal is covered by
/// `FileScannerTests`.
final class ScanResultTests: XCTestCase {

    private func makeFile(
        path: String = "/tmp/file",
        size: Int64,
        category: ScanCategory
    ) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: Date(timeIntervalSince1970: 0),
            lastModifiedDate: Date(timeIntervalSince1970: 0),
            category: category
        )
    }

    // MARK: - Total size

    func test_totalSize_sumsAllItemSizes() {
        let files = [
            makeFile(size: 100, category: .userCache),
            makeFile(size: 250, category: .systemCache),
            makeFile(size: 50, category: .trash)
        ]
        let result = ScanResult(items: files)

        XCTAssertEqual(result.totalSize, 400)
    }

    func test_totalSize_isZeroForEmptyResult() {
        let result = ScanResult(items: [])
        XCTAssertEqual(result.totalSize, 0)
    }

    // MARK: - Grouping

    func test_itemsByCategory_groupsRecordsBySharedCategory() {
        let files = [
            makeFile(path: "/tmp/a", size: 1, category: .userCache),
            makeFile(path: "/tmp/b", size: 2, category: .userCache),
            makeFile(path: "/tmp/c", size: 3, category: .trash)
        ]
        let result = ScanResult(items: files)

        XCTAssertEqual(result.itemsByCategory[.userCache]?.count, 2)
        XCTAssertEqual(result.itemsByCategory[.trash]?.count, 1)
        XCTAssertNil(result.itemsByCategory[.systemCache])
    }

    func test_sizeByCategory_sumsWithinEachCategory() {
        let files = [
            makeFile(path: "/tmp/a", size: 100, category: .userCache),
            makeFile(path: "/tmp/b", size: 200, category: .userCache),
            makeFile(path: "/tmp/c", size: 50, category: .trash)
        ]
        let result = ScanResult(items: files)

        XCTAssertEqual(result.sizeByCategory[.userCache], 300)
        XCTAssertEqual(result.sizeByCategory[.trash], 50)
    }

    // MARK: - Formatted total size

    /// `formattedTotalSize` should round-trip through `ByteCountFormatter`
    /// (file-size style) so the UI never has to format byte counts itself.
    /// Non-empty + containing "KB" for a kilobyte-scale value is enough to
    /// pin the contract without coupling to locale-specific punctuation.
    func test_formattedTotalSize_usesByteCountFormatterFileStyle() {
        let files = [makeFile(size: 1_500, category: .userCache)]
        let result = ScanResult(items: files)

        XCTAssertFalse(result.formattedTotalSize.isEmpty)
        XCTAssertTrue(
            result.formattedTotalSize.contains("KB"),
            "Expected KB suffix in '\(result.formattedTotalSize)'"
        )
    }
}
