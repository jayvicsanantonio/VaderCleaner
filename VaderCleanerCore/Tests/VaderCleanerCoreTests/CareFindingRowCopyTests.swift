// CareFindingRowCopyTests.swift
// Tests the results feed's compact copy: each kind's one-line summary, the amount a ready row shows, and the picked note on a your-call card.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct CareFindingRowCopyTests {

    private static func file(_ path: String, size: Int64) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache)
    }

    private static let junk = CareFinding(payload: .junk(ScanResult(items: [
        Self.file("/cache/a", size: 3_000_000),
        Self.file("/cache/b", size: 1_000_000),
    ])))

    private static let updates = CareFinding(payload: .maintenanceDue(taskIDs: ["a", "b", "c"]))

    // MARK: - Summary line

    @Test(arguments: CareFinding.Kind.allCases)
    func everyKindHasAShortSummaryOfItsOwn(kind: CareFinding.Kind) {
        let summary = CareFindingCopy.summary(for: kind)
        #expect(!summary.isEmpty)
        #expect(summary.count <= 52, "a row shows it on one line")
        #expect(summary != CareFindingCopy.title(for: kind))
    }

    @Test func summariesAreDistinct() {
        let summaries = Set(CareFinding.Kind.allCases.map(CareFindingCopy.summary(for:)))
        #expect(summaries.count == CareFinding.Kind.allCases.count)
    }

    // MARK: - Ready-row amount

    @Test func fullySelectedSizedFindingShowsItsTotalAlone() {
        let amount = CareFindingCopy.rowAmount(for: Self.junk, selectedBytes: 4_000_000, selectedCount: 2)
        #expect(amount.primary == CareFindingCopy.formattedBytes(4_000_000))
        #expect(amount.secondary == nil)
    }

    @Test func partlySelectedSizedFindingLeadsWithWhatFixTakes() {
        let amount = CareFindingCopy.rowAmount(for: Self.junk, selectedBytes: 3_000_000, selectedCount: 1)
        #expect(amount.primary == CareFindingCopy.formattedBytes(3_000_000))
        #expect(amount.secondary == "of \(CareFindingCopy.formattedBytes(4_000_000)) found")
    }

    @Test func clearedSizedFindingShowsTheTotalAndSaysSo() {
        let amount = CareFindingCopy.rowAmount(for: Self.junk, selectedBytes: 0, selectedCount: 0)
        #expect(amount.primary == CareFindingCopy.formattedBytes(4_000_000))
        #expect(amount.secondary == "None selected")
    }

    @Test(arguments: [(3, nil), (2, "2 selected"), (0, "None selected")] as [(Int, String?)])
    func countFindingShowsItsMetricAndAnyShortfall(selectedCount: Int, secondary: String?) {
        let amount = CareFindingCopy.rowAmount(for: Self.updates, selectedBytes: 0, selectedCount: selectedCount)
        #expect(amount.primary == CareFindingCopy.metric(for: Self.updates))
        #expect(amount.secondary == secondary)
    }

    // MARK: - Your-call picked note

    @Test func pickedNoteBeforeAnythingIsChosen() {
        #expect(CareFindingCopy.pickedNote(hasSize: true, selectedBytes: 0, selectedCount: 0) == "Nothing picked yet")
    }

    @Test func pickedNoteForSizedFindingsReportsBytes() {
        let note = CareFindingCopy.pickedNote(hasSize: true, selectedBytes: 2_000_000, selectedCount: 3)
        #expect(note == "\(CareFindingCopy.formattedBytes(2_000_000)) picked")
    }

    @Test func pickedNoteForCountFindingsReportsItems() {
        #expect(CareFindingCopy.pickedNote(hasSize: false, selectedBytes: 0, selectedCount: 4) == "4 picked")
    }
}
