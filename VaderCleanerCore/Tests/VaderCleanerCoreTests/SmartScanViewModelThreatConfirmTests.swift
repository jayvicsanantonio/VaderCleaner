// SmartScanViewModelThreatConfirmTests.swift
// Tests that a Run which would permanently delete malware threats raises the confirmation sheet first, and that declining the threats or running junk alone keeps the existing gate.

import Foundation
import Testing
@testable import VaderCleanerCore

/// Threats are pre-approved and pre-selected, and `MalwareThreatRemover`
/// deletes them outright rather than moving them to the Trash. A Run whose
/// only irreversible work is threat removal must therefore stop at the sheet
/// exactly as a junk delete does; one tap on the disc must not erase files
/// the user never saw listed.
@MainActor
@Suite struct SmartScanViewModelThreatConfirmTests {

    // MARK: - Fixtures

    private nonisolated static func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private nonisolated static let threats = [
        MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.pkg"), threatName: "Eicar"),
        MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil2.dmg"), threatName: "Eicar"),
    ]

    private nonisolated static func plan(_ findings: [CareFinding], units: [CareScanUnit]) -> CarePlan {
        CarePlan(
            findings: findings,
            health: nil,
            unitOutcomes: Dictionary(uniqueKeysWithValues: units.map { ($0, .completed) }),
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    /// Threats are the only finding, so threat removal is the only work a Run
    /// would do.
    private nonisolated static var threatsOnlyPlan: CarePlan {
        plan([CareFinding(payload: .threats(threats))], units: [.malware])
    }

    /// Threats beside a pre-approved, Trash-safe duplicate copy, so declining
    /// the threats still leaves work for the Run.
    private nonisolated static var threatsAndDuplicatesPlan: CarePlan {
        let dupGroup = DuplicateGroup(files: [
            Self.file("/Downloads/original", size: 40),
            Self.file("/Downloads/copy", size: 40),
        ])
        return plan(
            [CareFinding(payload: .threats(threats)), CareFinding(payload: .duplicates([dupGroup]))],
            units: [.malware, .duplicates]
        )
    }

    /// One safe junk file and nothing else.
    private nonisolated static var junkOnlyPlan: CarePlan {
        let junk = ScanResult(items: [Self.file("/cache/safe", size: 1_000, category: .userCache)])
        return plan([CareFinding(payload: .junk(junk))], units: [.systemJunk])
    }

    private func scannedViewModel(
        plan: CarePlan,
        removedThreats: TestBox<[URL]> = TestBox([]),
        recycled: TestBox<[URL]> = TestBox([]),
        cleanedJunk: TestBox<[URL]> = TestBox([])
    ) async -> SmartScanViewModel {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in plan },
            junkCleaner: { files in
                cleanedJunk.withLock { $0 += files.map(\.url) }
                return files.reduce(0) { $0 + $1.size }
            },
            threatRemover: { threats in
                removedThreats.withLock { $0 += threats.map(\.filePath) }
                return []
            },
            recycleFiles: { urls in
                recycled.withLock { $0 += urls }
                return Set(urls)
            }
        )
        await vm.scan()
        return vm
    }

    // MARK: - Threats raise the sheet

    @Test func threatsOnlyRunIsAPermanentDelete() async {
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan)
        #expect(vm.runIncludesPermanentDelete, "threat removal bypasses the Trash")
    }

    @Test func requestRunWithOnlyThreatsConfirmsWithoutRemovingAnything() async throws {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan, removedThreats: removed)

        await vm.requestRun()

        #expect(vm.isConfirmingRun, "a permanent threat delete must confirm first")
        #expect(removed.value.isEmpty, "no threat is deleted until the user confirms")
        #expect(!vm.isRunDiscVisible, "the disc hides behind the sheet")
        guard case .results = vm.phase else {
            Issue.record("expected to stay on the results feed, got \(vm.phase)")
            return
        }
    }

    @Test func confirmRunRemovesTheSelectedThreats() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan, removedThreats: removed)

        await vm.requestRun()
        await vm.confirmRun()

        #expect(!vm.isConfirmingRun)
        #expect(Set(removed.value) == Set(Self.threats.map(\.filePath)))
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    @Test func cancelRunLeavesTheThreatsOnDisk() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan, removedThreats: removed)

        await vm.requestRun()
        vm.cancelRun()

        #expect(!vm.isConfirmingRun)
        #expect(removed.value.isEmpty, "cancel leaves the Mac untouched")
        #expect(vm.isRunDiscVisible, "the disc returns after cancel")
    }

    // MARK: - Declined threats skip the sheet

    @Test func deselectedThreatsRunTrashSafeWorkWithoutConfirming() async {
        let removed = TestBox<[URL]>([])
        let recycled = TestBox<[URL]>([])
        let vm = await scannedViewModel(
            plan: Self.threatsAndDuplicatesPlan,
            removedThreats: removed,
            recycled: recycled
        )
        vm.setAllThreats(selected: false)

        #expect(!vm.runIncludesPermanentDelete, "with no threat checked, only the Trash-safe copy is left")
        await vm.requestRun()

        #expect(!vm.isConfirmingRun, "no irreversible step, so no sheet")
        #expect(removed.value.isEmpty, "an unchecked threat is never deleted")
        #expect(recycled.value == [URL(fileURLWithPath: "/Downloads/copy")], "the duplicate copy still runs on one tap")
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    @Test func excludedThreatCardRunsTrashSafeWorkWithoutConfirming() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsAndDuplicatesPlan, removedThreats: removed)
        vm.setFindingIncluded(.threats, false)

        await vm.requestRun()

        #expect(!vm.isConfirmingRun, "an excluded threat card is not work the run will do")
        #expect(removed.value.isEmpty)
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    // MARK: - Junk keeps its gate

    @Test func junkOnlyRunStillConfirmsFirst() async {
        let cleaned = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.junkOnlyPlan, cleanedJunk: cleaned)

        #expect(vm.runIncludesPermanentDelete)
        await vm.requestRun()

        #expect(vm.isConfirmingRun, "a permanent junk delete still confirms first")
        #expect(cleaned.value.isEmpty, "nothing is cleaned until the user confirms")
        #expect(vm.runActionSummary.map(\.kind) == [.junkCleanup])
        #expect(vm.runActionSummary.first?.isPermanent == true)
    }

    // MARK: - Sheet summary

    @Test func threatLineIsFlaggedPermanentAndSaysSo() async throws {
        let vm = await scannedViewModel(plan: Self.threatsAndDuplicatesPlan)
        let summary = vm.runActionSummary

        let threatLine = try #require(summary.first { $0.kind == .threats })
        #expect(threatLine.isPermanent, "the sheet must mark threat removal as irreversible")
        #expect(threatLine.text == "Permanently removes 2 threats")
        #expect(summary.first { $0.kind == .duplicates }?.isPermanent == false, "duplicates still go to the Trash")
    }
}
