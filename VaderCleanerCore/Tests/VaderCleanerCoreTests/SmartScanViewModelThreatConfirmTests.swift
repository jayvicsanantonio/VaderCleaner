// SmartScanViewModelThreatConfirmTests.swift
// Tests that a Run which would permanently delete a malware threat in a protected path raises the confirmation sheet first, while threats in the user's own folders go to the Trash on one tap, and that junk keeps its existing gate.

import Foundation
import Testing
@testable import VaderCleanerCore

/// Threats are pre-approved and pre-selected. `MalwareThreatRemover` moves
/// the ones in the user's own folders to the Trash, so those are as
/// recoverable as any other Trash-bound finding. Threats under protected
/// system paths can only be removed by the privileged helper, which deletes
/// them outright; a Run that includes one must stop at the sheet exactly as a
/// junk delete does, so one tap on the disc can't erase what the Trash can't
/// give back.
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

    /// Threats in the user's own folders — removed to the Trash.
    private nonisolated static let userThreats = [
        MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.pkg"), threatName: "Eicar"),
        MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil2.dmg"), threatName: "Eicar"),
    ]

    /// A threat under a protected prefix — only the helper can remove it, and
    /// it deletes outright.
    private nonisolated static let protectedThreat = MalwareThreat(
        filePath: URL(fileURLWithPath: "/Library/LaunchDaemons/com.bogus.plist"),
        threatName: "OSX.Bad"
    )

    private nonisolated static var allThreats: [MalwareThreat] { userThreats + [protectedThreat] }

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
    private nonisolated static func threatsOnlyPlan(_ threats: [MalwareThreat]) -> CarePlan {
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
            [CareFinding(payload: .threats(allThreats)), CareFinding(payload: .duplicates([dupGroup]))],
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

    // MARK: - Threats in the user's folders go to the Trash on one tap

    @Test func userFolderThreatsRunWithoutConfirming() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan(Self.userThreats), removedThreats: removed)

        #expect(!vm.runIncludesPermanentDelete, "threats in the user's folders go to the Trash")
        await vm.requestRun()

        #expect(!vm.isConfirmingRun, "nothing irreversible, so no sheet")
        #expect(Set(removed.value) == Set(Self.userThreats.map(\.filePath)))
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    // MARK: - A protected threat raises the sheet

    @Test func protectedThreatRaisesConfirmationWithoutRemovingAnything() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan(Self.allThreats), removedThreats: removed)

        #expect(vm.runIncludesPermanentDelete, "the helper deletes a protected threat outright")
        await vm.requestRun()

        #expect(vm.isConfirmingRun, "a permanent threat delete must confirm first")
        #expect(removed.value.isEmpty, "no threat is removed until the user confirms")
        #expect(!vm.isRunDiscVisible, "the disc hides behind the sheet")
        guard case .results = vm.phase else {
            Issue.record("expected to stay on the results feed, got \(vm.phase)")
            return
        }
    }

    @Test func confirmRunRemovesTheSelectedThreats() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan(Self.allThreats), removedThreats: removed)

        await vm.requestRun()
        await vm.confirmRun()

        #expect(!vm.isConfirmingRun)
        #expect(Set(removed.value) == Set(Self.allThreats.map(\.filePath)))
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    @Test func cancelRunLeavesTheThreatsOnDisk() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan(Self.allThreats), removedThreats: removed)

        await vm.requestRun()
        vm.cancelRun()

        #expect(!vm.isConfirmingRun)
        #expect(removed.value.isEmpty, "cancel leaves the Mac untouched")
        #expect(vm.isRunDiscVisible, "the disc returns after cancel")
    }

    @Test func deselectingTheProtectedThreatSkipsTheSheet() async {
        let removed = TestBox<[URL]>([])
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan(Self.allThreats), removedThreats: removed)
        vm.toggleThreat(Self.protectedThreat)

        #expect(!vm.runIncludesPermanentDelete, "only Trash-bound threats are left selected")
        await vm.requestRun()

        #expect(!vm.isConfirmingRun)
        #expect(Set(removed.value) == Set(Self.userThreats.map(\.filePath)), "the unchecked protected threat is left alone")
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
        #expect(removed.value.isEmpty, "an unchecked threat is never removed")
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

    /// The threat line says where the chosen threats are going, and is tagged
    /// permanent only when at least one can't go to the Trash.
    @Test(arguments: [
        (Self.userThreats, "Moves 2 threats to the Trash", false),
        ([Self.protectedThreat], "Permanently removes 1 threat", true),
        (Self.allThreats, "Removes 3 threats, 1 of them permanently", true),
    ])
    func threatLineSaysWhereTheThreatsGo(threats: [MalwareThreat], text: String, isPermanent: Bool) async throws {
        let vm = await scannedViewModel(plan: Self.threatsOnlyPlan(threats))

        let threatLine = try #require(vm.runActionSummary.first { $0.kind == .threats })
        #expect(threatLine.text == text)
        #expect(threatLine.isPermanent == isPermanent)
    }

    @Test func duplicatesLineStaysTrashBoundBesideAPermanentThreat() async {
        let vm = await scannedViewModel(plan: Self.threatsAndDuplicatesPlan)
        #expect(vm.runActionSummary.first { $0.kind == .duplicates }?.isPermanent == false, "duplicates still go to the Trash")
    }
}
