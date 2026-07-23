// SmartScanViewModelConfirmTests.swift
// Tests the disc caption's live numbers and the run-confirmation gate: scope counts, freeable bytes, and the permanent-delete confirm/cancel state machine.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelConfirmTests: XCTestCase {

    // MARK: - Fixtures

    private nonisolated func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    /// Junk (pre-approved, one safe file), duplicates (pre-approved, seeds its
    /// redundant copy), and one opt-in large file that stays out until chosen.
    private nonisolated var plan: CarePlan {
        let junk = ScanResult(items: [file("/cache/safe", size: 1_000, category: .userCache)])
        let dupGroup = DuplicateGroup(files: [
            file("/Downloads/original", size: 40),
            file("/Downloads/copy", size: 40)
        ])
        let bigFile = file("/Movies/huge.mov", size: 9_000, category: .largeFile)
        return CarePlan(
            findings: [
                CareFinding(kind: .junkCleanup, payload: .junk(junk)),
                CareFinding(kind: .duplicates, payload: .duplicates([dupGroup])),
                CareFinding(kind: .largeOldFiles, payload: .largeOldFiles([bigFile])),
            ],
            health: nil,
            unitOutcomes: [.systemJunk: .completed, .duplicates: .completed, .largeOldFiles: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    private func scannedViewModel(runRecorder: (() -> Void)? = nil) async -> SmartScanViewModel {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.plan },
            junkCleaner: { files in runRecorder?(); return files.reduce(0) { $0 + $1.size } },
            recycleFiles: { runRecorder?(); return Set($0) }
        )
        await vm.scan()
        return vm
    }

    // MARK: - Caption numbers

    func test_runnableCountAndBytes_reflectPreApprovedSeed() async {
        let vm = await scannedViewModel()
        // Junk + duplicates seed on; the opt-in large file stays out.
        XCTAssertEqual(vm.runnableFindingCount, 2)
        XCTAssertEqual(vm.freeableBytes, 1_000 + 40, "one safe junk file plus the redundant duplicate copy")
    }

    func test_optInSelection_growsCountAndBytesLive() async {
        let vm = await scannedViewModel()
        vm.setLargeOldFiles([URL(fileURLWithPath: "/Movies/huge.mov")], selected: true)
        XCTAssertEqual(vm.runnableFindingCount, 3, "choosing the opt-in file joins it to the run")
        XCTAssertEqual(vm.freeableBytes, 1_000 + 40 + 9_000)
    }

    func test_excludingJunk_dropsItsBytesFromTheCaption() async {
        let vm = await scannedViewModel()
        vm.setFindingIncluded(.junkCleanup, false)
        XCTAssertEqual(vm.runnableFindingCount, 1)
        XCTAssertEqual(vm.freeableBytes, 40, "only the duplicate copy remains")
    }

    // MARK: - Freeable bytes reflect the safe selection

    func test_freeableBytes_forJunk_countsOnlyTheSafeSelection() async {
        // Junk found in an unsafe category (mail attachments) seeds unchecked,
        // so what Fix frees — and the tile metric — is the safe subset only,
        // not the gross total the scanner found.
        let junk = ScanResult(items: [
            file("/cache/safe", size: 1_000, category: .userCache),
            file("/mail/attachment", size: 5_000, category: .mailAttachments),
        ])
        let plan = CarePlan(
            findings: [CareFinding(kind: .junkCleanup, payload: .junk(junk))],
            health: nil,
            unitOutcomes: [.systemJunk: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
        let vm = SmartScanViewModel(scanEngine: { _, _ in plan })
        await vm.scan()

        XCTAssertEqual(vm.junkResult.totalSize, 6_000, "the gross total the card used to show")
        XCTAssertEqual(vm.freeableBytes(for: .junkCleanup), 1_000, "only the safe-category junk is selected")
        XCTAssertEqual(vm.preApprovedFreeableBytes, 1_000, "the hero reflects the same safe subset")
    }

    func test_preApprovedFreeableBytes_sumsJunkAndDuplicates() async {
        let vm = await scannedViewModel()
        // Junk safe file (1,000) + the seeded redundant duplicate copy (40).
        XCTAssertEqual(vm.preApprovedFreeableBytes, 1_040)
    }

    func test_preApprovedCount_countsFixHandledFindingsNotOptIn() async {
        // The plan has junk + duplicates (pre-approved) and one opt-in large
        // file — the hero's count must not include the opt-in item.
        let vm = await scannedViewModel()
        XCTAssertEqual(vm.preApprovedCount, 2, "junk and duplicates; the large-old file is opt-in")
    }

    // MARK: - Permanent-delete detection

    func test_runIncludesPermanentDelete_trueWhenJunkIncluded() async {
        let vm = await scannedViewModel()
        XCTAssertTrue(vm.runIncludesPermanentDelete)
    }

    func test_runIncludesPermanentDelete_falseOnceJunkExcluded() async {
        let vm = await scannedViewModel()
        vm.setFindingIncluded(.junkCleanup, false)
        XCTAssertFalse(vm.runIncludesPermanentDelete, "duplicates and files go to the Trash, not a permanent delete")
    }

    // MARK: - Confirmation gate

    func test_requestRun_withJunk_raisesConfirmationWithoutRunning() async {
        var ran = false
        let vm = await scannedViewModel(runRecorder: { ran = true })
        await vm.requestRun()
        XCTAssertTrue(vm.isConfirmingRun, "a permanent junk delete must confirm first")
        XCTAssertFalse(ran, "nothing runs until the user confirms")
        XCTAssertFalse(vm.isRunDiscVisible, "the disc hides behind the sheet")
        guard case .results = vm.phase else { return XCTFail("still on the results feed") }
    }

    func test_requestRun_withoutPermanentDelete_runsImmediately() async {
        var ran = false
        let vm = await scannedViewModel(runRecorder: { ran = true })
        vm.setFindingIncluded(.junkCleanup, false) // leaves only Trash-safe duplicates
        await vm.requestRun()
        XCTAssertFalse(vm.isConfirmingRun, "no irreversible step, so no sheet")
        XCTAssertTrue(ran, "the run proceeds on one tap")
        guard case .done = vm.phase else { return XCTFail("expected .done, got \(vm.phase)") }
    }

    func test_confirmRun_executesAndClearsTheSheet() async {
        var ran = false
        let vm = await scannedViewModel(runRecorder: { ran = true })
        await vm.requestRun()
        await vm.confirmRun()
        XCTAssertFalse(vm.isConfirmingRun)
        XCTAssertTrue(ran)
        guard case .done = vm.phase else { return XCTFail("expected .done, got \(vm.phase)") }
    }

    func test_cancelRun_dismissesWithoutRunning() async {
        var ran = false
        let vm = await scannedViewModel(runRecorder: { ran = true })
        await vm.requestRun()
        vm.cancelRun()
        XCTAssertFalse(vm.isConfirmingRun)
        XCTAssertFalse(ran, "cancel leaves the Mac untouched")
        XCTAssertTrue(vm.isRunDiscVisible, "the disc returns after cancel")
        guard case .results = vm.phase else { return XCTFail("back on the results feed") }
    }

    func test_confirmRun_isNoOpWhenNotConfirming() async {
        var ran = false
        let vm = await scannedViewModel(runRecorder: { ran = true })
        await vm.confirmRun()
        XCTAssertFalse(ran, "confirm without a pending sheet does nothing")
    }

    // MARK: - Sheet summary

    func test_runActionSummary_listsRunnableFindingsAndFlagsThePermanentOne() async {
        let vm = await scannedViewModel()
        let summary = vm.runActionSummary
        XCTAssertEqual(summary.map(\.kind), [.junkCleanup, .duplicates], "one line per runnable finding, in feed order")

        let junkLine = summary.first { $0.kind == .junkCleanup }
        XCTAssertEqual(junkLine?.isPermanent, true, "only junk is the permanent delete")
        XCTAssertTrue(junkLine?.text.contains("Permanently") == true, "the junk line names it as permanent: \(junkLine?.text ?? "")")

        XCTAssertEqual(summary.first { $0.kind == .duplicates }?.isPermanent, false)
    }

    func test_runActionSummary_excludesOptInFindingsUntilChosen() async {
        let vm = await scannedViewModel()
        XCTAssertFalse(vm.runActionSummary.contains { $0.kind == .largeOldFiles })
        vm.setLargeOldFiles([URL(fileURLWithPath: "/Movies/huge.mov")], selected: true)
        XCTAssertTrue(vm.runActionSummary.contains { $0.kind == .largeOldFiles }, "the chosen opt-in file joins the summary")
    }
}
