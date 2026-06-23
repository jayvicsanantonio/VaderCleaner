// DownloadsScannerTests.swift
// Pins the Downloads source-attribution helpers: quarantine agents map to friendly browser names, and the dominant source is the one contributing the most bytes.

import XCTest
@testable import VaderCleaner

final class DownloadsScannerTests: XCTestCase {

    private func file(_ path: String, size: Int64) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .largeFile
        )
    }

    func test_dominantSourceIsLargestByBytes() {
        let items = [
            DownloadItem(file: file("/d/a.dmg", size: 100), sourceApp: "Safari"),
            DownloadItem(file: file("/d/b.zip", size: 900), sourceApp: "Google Chrome"),
            DownloadItem(file: file("/d/c.pdf", size: 200), sourceApp: "Google Chrome"),
        ]
        XCTAssertEqual(DownloadsScanner.dominantSource(of: items), "Google Chrome")
    }

    func test_dominantSourceIgnoresUnattributedFiles() {
        let items = [
            DownloadItem(file: file("/d/a.dmg", size: 999), sourceApp: nil),
            DownloadItem(file: file("/d/b.zip", size: 10), sourceApp: "Safari"),
        ]
        XCTAssertEqual(
            DownloadsScanner.dominantSource(of: items),
            "Safari",
            "Files with no recorded source must not count toward the dominant source"
        )
    }

    func test_dominantSourceNilWhenNothingAttributed() {
        let items = [DownloadItem(file: file("/d/a.dmg", size: 999), sourceApp: nil)]
        XCTAssertNil(DownloadsScanner.dominantSource(of: items))
    }
}
