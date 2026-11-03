// CareRunSummaryTests.swift
// Tests the results summary's numbers and copy: one total for what Fix acts on, split into what is deleted now and what goes to the Trash.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct CareRunSummaryTests {

    private static func bytes(_ value: Int64) -> String {
        CareFindingCopy.formattedBytes(value)
    }

    // MARK: - Split

    @Test func trashedBytesAreTheTotalLessWhatIsDeleted() {
        let summary = CareRunSummary(totalBytes: 1_000, deletedBytes: 250, fixCount: 2, decideCount: 0)
        #expect(summary.trashedBytes == 750)
        #expect(summary.deletedFraction == 0.25)
    }

    @Test func deletedFractionIsZeroWithNothingToClean() {
        let summary = CareRunSummary(totalBytes: 0, deletedBytes: 0, fixCount: 1, decideCount: 0)
        #expect(summary.deletedFraction == 0)
    }

    // MARK: - Headline

    @Test func headlineLeadsWithTheWholeTotal() {
        let summary = CareRunSummary(totalBytes: 68_000_000_000, deletedBytes: 2_000_000_000, fixCount: 4, decideCount: 6)
        #expect(summary.headline == "\(Self.bytes(68_000_000_000)) ready to clean")
    }

    @Test(arguments: [(1, "1 fix ready"), (3, "3 fixes ready")])
    func headlineCountsFixesWhenNothingIsMeasuredInBytes(fixCount: Int, headline: String) {
        let summary = CareRunSummary(totalBytes: 0, deletedBytes: 0, fixCount: fixCount, decideCount: 0)
        #expect(summary.headline == headline)
    }

    @Test func headlineIsAbsentWhenFixHasNothingToDo() {
        let summary = CareRunSummary(totalBytes: 0, deletedBytes: 0, fixCount: 0, decideCount: 3)
        #expect(summary.headline == nil)
    }

    // MARK: - Breakdown

    @Test func breakdownNamesBothShares() {
        let summary = CareRunSummary(totalBytes: 3_000_000, deletedBytes: 1_000_000, fixCount: 2, decideCount: 0)
        #expect(summary.breakdown == "\(Self.bytes(1_000_000)) deleted now · \(Self.bytes(2_000_000)) goes to the Trash")
    }

    @Test func breakdownForADeleteOnlyRun() {
        let summary = CareRunSummary(totalBytes: 1_000_000, deletedBytes: 1_000_000, fixCount: 1, decideCount: 0)
        #expect(summary.breakdown == "All of it is deleted for good — your Mac rebuilds what it needs.")
    }

    @Test func breakdownForATrashOnlyRun() {
        let summary = CareRunSummary(totalBytes: 1_000_000, deletedBytes: 0, fixCount: 1, decideCount: 0)
        #expect(summary.breakdown == "All of it goes to the Trash, so you can change your mind.")
    }

    @Test func breakdownIsAbsentWithoutBytes() {
        let summary = CareRunSummary(totalBytes: 0, deletedBytes: 0, fixCount: 2, decideCount: 0)
        #expect(summary.breakdown == nil)
    }

    // MARK: - Plan line

    @Test(arguments: [
        (4, 6, "4 included in Fix · 6 for you to decide"),
        (1, 1, "1 included in Fix · 1 for you to decide"),
        (2, 0, "2 included in Fix"),
        (0, 3, "3 for you to decide"),
    ])
    func planLineCountsWhatIsIncludedAndWhatIsLeftToDecide(fixCount: Int, decideCount: Int, line: String) {
        let summary = CareRunSummary(totalBytes: 0, deletedBytes: 0, fixCount: fixCount, decideCount: decideCount)
        #expect(summary.planLine == line)
    }

    @Test func planLineIsAbsentWhenThereIsNothingToCount() {
        let summary = CareRunSummary(totalBytes: 0, deletedBytes: 0, fixCount: 0, decideCount: 0)
        #expect(summary.planLine == nil)
    }
}

/// The view model's summary has to agree with what a Run actually does: every
/// executing finding's selection counts toward the total, and only the junk
/// the Trash can't take counts as deleted now.
@MainActor
@Suite struct SmartScanRunSummaryTests {

    private nonisolated static func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    /// Junk with one permanent (system cache) and one Trash-bound (user cache)
    /// file, duplicates seeding one 40-byte copy, and one opt-in large file.
    private nonisolated static var plan: CarePlan {
        let junk = ScanResult(items: [
            Self.file("/Library/Caches/system", size: 1_000, category: .systemCache),
            Self.file("/Users/me/Library/Caches/app", size: 500, category: .userCache),
        ])
        let dupGroup = DuplicateGroup(files: [
            Self.file("/Downloads/original", size: 40),
            Self.file("/Downloads/copy", size: 40),
        ])
        let bigFile = Self.file("/Movies/huge.mov", size: 9_000, category: .largeFile)
        return CarePlan(
            findings: [
                CareFinding(payload: .junk(junk)),
                CareFinding(payload: .duplicates([dupGroup])),
                CareFinding(payload: .largeOldFiles([bigFile])),
            ],
            health: nil,
            unitOutcomes: [.systemJunk: .completed, .duplicates: .completed, .largeOldFiles: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    private func scannedViewModel() async -> SmartScanViewModel {
        let vm = SmartScanViewModel(scanEngine: { _, _ in Self.plan })
        await vm.scan()
        return vm
    }

    @Test func totalCountsEverythingFixActsOn() async {
        let vm = await scannedViewModel()
        let summary = vm.runSummary
        #expect(summary.totalBytes == 1_540, "both junk files plus the duplicate copy")
        #expect(summary.deletedBytes == 1_000, "only the system cache bypasses the Trash")
        #expect(summary.trashedBytes == 540)
        #expect(summary.fixCount == 2)
        #expect(summary.decideCount == 1, "the large file is still the user's call")
    }

    @Test func pickingAnOptInFileMovesItIntoTheTotal() async {
        let vm = await scannedViewModel()
        vm.setLargeOldFiles([URL(fileURLWithPath: "/Movies/huge.mov")], selected: true)
        let summary = vm.runSummary
        #expect(summary.totalBytes == 10_540)
        #expect(summary.trashedBytes == 9_540)
        #expect(summary.fixCount == 3)
        #expect(summary.decideCount == 0, "a picked card is decided")
    }

    @Test func excludingJunkDropsItFromBothShares() async {
        let vm = await scannedViewModel()
        vm.setFindingIncluded(.junkCleanup, false)
        let summary = vm.runSummary
        #expect(summary.totalBytes == 40)
        #expect(summary.deletedBytes == 0)
        #expect(summary.fixCount == 1)
    }
}
