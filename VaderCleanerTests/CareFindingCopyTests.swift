// CareFindingCopyTests.swift
// Tests the deterministic plain-language catalog: every finding kind has distinct, non-empty copy, metrics pluralize, and byte formatting matches Finder style.

import XCTest
@testable import VaderCleaner

final class CareFindingCopyTests: XCTestCase {

    func test_everyKind_hasNonEmptyDistinctTitles() {
        var titles = Set<String>()
        for kind in CareFinding.Kind.allCases {
            let title = CareFindingCopy.title(for: kind)
            XCTAssertFalse(title.isEmpty, "\(kind) needs a title")
            titles.insert(title)
        }
        XCTAssertEqual(titles.count, CareFinding.Kind.allCases.count, "titles must be distinct")
    }

    func test_everyKind_hasNonEmptyExplanationAndVerb() {
        for kind in CareFinding.Kind.allCases {
            XCTAssertFalse(CareFindingCopy.explanation(for: kind).isEmpty, "\(kind) needs an explanation")
            XCTAssertFalse(CareFindingCopy.actionVerb(for: kind).isEmpty, "\(kind) needs an action verb")
        }
    }

    func test_everyActionability_hasASafetyLine() {
        XCTAssertFalse(CareFindingCopy.safetyLine(for: .preApproved).isEmpty)
        XCTAssertFalse(CareFindingCopy.safetyLine(for: .optIn).isEmpty)
        XCTAssertFalse(CareFindingCopy.safetyLine(for: .informational).isEmpty)
        XCTAssertNotEqual(
            CareFindingCopy.safetyLine(for: .preApproved),
            CareFindingCopy.safetyLine(for: .optIn),
            "safe and opt-in findings must read differently"
        )
    }

    func test_metric_byteKinds_useFinderStyleBytes() {
        let file = ScannedFile(
            url: URL(fileURLWithPath: "/cache/blob"),
            size: 2_300_000_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let finding = CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [file])))
        XCTAssertEqual(CareFindingCopy.metric(for: finding), CareFindingCopy.formattedBytes(2_300_000_000))
    }

    func test_metric_countKinds_pluralize() {
        let one = CareFinding(
            kind: .threats,
            payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/a"), threatName: "T")])
        )
        let two = CareFinding(
            kind: .threats,
            payload: .threats([
                MalwareThreat(filePath: URL(fileURLWithPath: "/a"), threatName: "T"),
                MalwareThreat(filePath: URL(fileURLWithPath: "/b"), threatName: "T")
            ])
        )
        XCTAssertTrue(CareFindingCopy.metric(for: one).contains("1"))
        XCTAssertTrue(CareFindingCopy.metric(for: two).contains("2"))
        // The singular form must differ beyond the digit ("1 threat found" vs
        // "2 threats found"), proving the stringsdict plural rule is wired.
        XCTAssertNotEqual(
            CareFindingCopy.metric(for: one).replacingOccurrences(of: "1", with: "2"),
            CareFindingCopy.metric(for: two)
        )
    }

    func test_metric_lowDiskSpace_showsPercentFull() {
        let finding = CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(DiskStats(usedBytes: 91, totalBytes: 100)))
        XCTAssertTrue(CareFindingCopy.metric(for: finding).contains("91"))
    }

    func test_formattedBytes_matchesFinderFileStyle() {
        let expected = ByteCountFormatter.string(fromByteCount: 2_300_000_000, countStyle: .file)
        XCTAssertEqual(CareFindingCopy.formattedBytes(2_300_000_000), expected)
    }

    // MARK: - Tile selection note

    func test_selectionNote_nothingSelected_readsNone() {
        XCTAssertEqual(
            CareFindingCopy.selectionNote(hasSize: true, selectedBytes: 0, selectedCount: 0),
            "None selected"
        )
        XCTAssertEqual(
            CareFindingCopy.selectionNote(hasSize: false, selectedBytes: 0, selectedCount: 0),
            "None selected"
        )
    }

    func test_selectionNote_sizedFinding_quotesSelectedBytes() {
        let note = CareFindingCopy.selectionNote(hasSize: true, selectedBytes: 94_770_000_000, selectedCount: 842)
        XCTAssertTrue(note.contains(CareFindingCopy.formattedBytes(94_770_000_000)), note)
        XCTAssertTrue(note.contains("selected"))
        XCTAssertFalse(note.contains("842"), "a sized finding reports bytes, not the raw count")
    }

    func test_selectionNote_countFinding_quotesSelectedCount() {
        let note = CareFindingCopy.selectionNote(hasSize: false, selectedBytes: 0, selectedCount: 2)
        XCTAssertTrue(note.contains("2"), note)
        XCTAssertTrue(note.contains("selected"))
    }
}
