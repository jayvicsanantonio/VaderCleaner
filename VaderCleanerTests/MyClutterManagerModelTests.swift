// MyClutterManagerModelTests.swift
// Pins the My Clutter Manager's pure classification and grouping: file-kind and size-bucket facets, facet filtering, and download-source grouping order.

import XCTest
@testable import VaderCleaner

final class MyClutterManagerModelTests: XCTestCase {

    private func file(_ path: String, size: Int64) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
    }

    func test_fileKindClassification() {
        XCTAssertEqual(MyClutterFileKind.of(URL(fileURLWithPath: "/a/movie.MOV")), .videos)
        XCTAssertEqual(MyClutterFileKind.of(URL(fileURLWithPath: "/a/archive.zip")), .archives)
        XCTAssertEqual(MyClutterFileKind.of(URL(fileURLWithPath: "/a/notes.pdf")), .other)
    }

    func test_sizeBucketThresholds() {
        XCTAssertEqual(MyClutterSizeBucket.of(6_000_000_000), .huge)
        XCTAssertEqual(MyClutterSizeBucket.of(2_000_000_000), .average)
        XCTAssertEqual(MyClutterSizeBucket.of(500_000_000), .small)
    }

    func test_facetFiltering() {
        let files = [
            file("/a/big.mov", size: 6_000_000_000),
            file("/a/mid.zip", size: 2_000_000_000),
            file("/a/small.pdf", size: 10_000),
        ]
        let selected: Set<URL> = [URL(fileURLWithPath: "/a/mid.zip")]

        XCTAssertEqual(MyClutterManagerModel.files(for: .all, in: files, isSelected: { selected.contains($0) }).count, 3)
        XCTAssertEqual(MyClutterManagerModel.files(for: .selected, in: files, isSelected: { selected.contains($0) }).map(\.url),
                       [URL(fileURLWithPath: "/a/mid.zip")])
        XCTAssertEqual(MyClutterManagerModel.files(for: .kind(.videos), in: files, isSelected: { _ in false }).map(\.url),
                       [URL(fileURLWithPath: "/a/big.mov")])
        XCTAssertEqual(MyClutterManagerModel.files(for: .size(.huge), in: files, isSelected: { _ in false }).map(\.url),
                       [URL(fileURLWithPath: "/a/big.mov")])
    }

    func test_downloadsGroupedBySourceOrderedByBytes() {
        let items = [
            DownloadItem(file: file("/d/a.dmg", size: 100), sourceApp: "Safari"),
            DownloadItem(file: file("/d/b.zip", size: 900), sourceApp: "Google Chrome"),
            DownloadItem(file: file("/d/c.pdf", size: 50), sourceApp: nil),
        ]
        let groups = MyClutterManagerModel.downloadsBySource(items)

        XCTAssertEqual(groups.first?.source, "Google Chrome", "Largest source by bytes comes first")
        XCTAssertEqual(groups.first?.bytes, 900)
        XCTAssertEqual(groups.count, 3, "Safari, Chrome, and the Other bucket")
    }
}
