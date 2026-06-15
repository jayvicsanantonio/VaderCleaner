// LargeOldFilesSummaryTests.swift
// Tests the pure header-summary strings the Large & Old Files results screen shows above its list — file count headline and the "older than 6 months · total" detail.

import XCTest
@testable import VaderCleaner

final class LargeOldFilesSummaryTests: XCTestCase {

    // MARK: - Headline

    /// The headline is the bare file count, pluralized — the list's primary
    /// "here's what the scan found" line.
    func test_headline_pluralizesFileCount() {
        XCTAssertEqual(LargeOldFilesSummary.headline(for: makeFiles(count: 3)), "3 files")
    }

    /// A single result must read "1 file", not "1 files".
    func test_headline_singularForOneFile() {
        XCTAssertEqual(LargeOldFilesSummary.headline(for: makeFiles(count: 1)), "1 file")
    }

    // MARK: - Found sentence

    /// The dashboard headline is a full sentence carrying the file count,
    /// echoing the Applications section's "We've found N apps" phrasing.
    func test_foundSentence_carriesFileCount() {
        let sentence = LargeOldFilesSummary.foundSentence(for: makeFiles(count: 51))
        XCTAssertTrue(sentence.contains("51"), "Expected the file count, got \(sentence)")
        XCTAssertTrue(sentence.contains("large or old files"),
                      "Expected the Large & Old phrasing, got \(sentence)")
    }

    // MARK: - Detail

    /// When some files qualified by age, the detail leads with the old-file
    /// count and then the total reclaimable size, separated by a middle dot.
    func test_detail_includesOldCountAndTotalSize() {
        let files = [
            makeFile(size: 1_000, category: .largeFile),
            makeFile(size: 2_000, category: .oldFile),
            makeFile(size: 3_000, category: .oldFile)
        ]
        let detail = LargeOldFilesSummary.detail(for: files)
        XCTAssertTrue(detail.contains("2 older than 6 months"),
                      "Expected the old-file count, got \(detail)")
        XCTAssertTrue(detail.contains("·"),
                      "Expected a middle-dot separator, got \(detail)")
        XCTAssertTrue(detail.contains("total"),
                      "Expected the total-size clause, got \(detail)")
    }

    /// With no age-qualified files the old-file clause is dropped entirely —
    /// the detail is just the total size so the line never reads
    /// "0 older than 6 months".
    func test_detail_dropsOldClauseWhenNoneQualify() {
        let files = [
            makeFile(size: 1_000, category: .largeFile),
            makeFile(size: 2_000, category: .largeFile)
        ]
        let detail = LargeOldFilesSummary.detail(for: files)
        XCTAssertFalse(detail.contains("older than"),
                       "Expected no old-file clause, got \(detail)")
        XCTAssertTrue(detail.contains("total"),
                      "Expected the total-size clause, got \(detail)")
    }

    /// A single old file reads "1 older than 6 months", not "1 older…s".
    func test_detail_singularOldFile() {
        let files = [makeFile(size: 1_000, category: .oldFile)]
        let detail = LargeOldFilesSummary.detail(for: files)
        XCTAssertTrue(detail.contains("1 older than 6 months"),
                      "Expected singular old-file phrasing, got \(detail)")
    }

    // MARK: - Helpers

    private func makeFiles(count: Int) -> [ScannedFile] {
        (0..<count).map { _ in makeFile(size: 1_000, category: .largeFile) }
    }

    private func makeFile(size: Int64, category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-summary/\(UUID().uuidString)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }
}
