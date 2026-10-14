// SmartScanViewModelPrivacyConfirmTests.swift
// Tests that a Run which would clear browser-privacy data raises the confirmation sheet first, and that leaving every category unchecked keeps Trash-safe work on one tap.

import Foundation
import Testing
@testable import VaderCleanerCore

/// `BrowserPrivacyRemover` deletes rows from the browsers' own databases and
/// removes their cache and session files outright; nothing reaches the Trash.
/// A Run that would clear a checked category must therefore stop at the sheet
/// exactly as a junk or threat delete does.
@MainActor
@Suite struct SmartScanViewModelPrivacyConfirmTests {

    // MARK: - Fixtures

    private nonisolated static let cookies = BrowserPrivacyKey(browser: .safari, category: .cookies)
    private nonisolated static let cachedFiles = BrowserPrivacyKey(browser: .safari, category: .cachedFiles)

    private nonisolated static var privacyFinding: CareFinding {
        CareFinding(payload: .browserPrivacy([
            BrowserPrivacySummary(browser: .safari, counts: [.cookies: 12, .cachedFiles: 30])
        ]))
    }

    private nonisolated static func plan(_ findings: [CareFinding], units: [CareScanUnit]) -> CarePlan {
        CarePlan(
            findings: findings,
            health: nil,
            unitOutcomes: Dictionary(uniqueKeysWithValues: units.map { ($0, .completed) }),
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    /// Browser privacy is the only finding, so clearing it is the only work a
    /// Run would do once a category is checked.
    private nonisolated static var privacyOnlyPlan: CarePlan {
        plan([privacyFinding], units: [.browserPrivacy])
    }

    /// Browser privacy beside a pre-approved, Trash-safe duplicate copy, so
    /// leaving every privacy category unchecked still leaves work for the Run.
    private nonisolated static var privacyAndDuplicatesPlan: CarePlan {
        let dupGroup = DuplicateGroup(files: [
            ScannedFile(url: URL(fileURLWithPath: "/Downloads/original"), size: 40, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache),
            ScannedFile(url: URL(fileURLWithPath: "/Downloads/copy"), size: 40, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache),
        ])
        return plan(
            [privacyFinding, CareFinding(payload: .duplicates([dupGroup]))],
            units: [.browserPrivacy, .duplicates]
        )
    }

    private func scannedViewModel(
        plan: CarePlan,
        clearedRequests: TestBox<[PrivacyRemovalRequest]> = TestBox([]),
        recycled: TestBox<[URL]> = TestBox([])
    ) async -> SmartScanViewModel {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in plan },
            recycleFiles: { urls in
                recycled.withLock { $0 += urls }
                return Set(urls)
            },
            privacyRemover: { requests in
                clearedRequests.withLock { $0 += requests }
            }
        )
        await vm.scan()
        return vm
    }

    // MARK: - A checked category raises the sheet

    @Test func checkedPrivacyRunIsAPermanentDelete() async {
        let vm = await scannedViewModel(plan: Self.privacyOnlyPlan)
        vm.toggleBrowserPrivacy(Self.cookies)

        #expect(vm.runIncludesPermanentDelete, "clearing browser data bypasses the Trash")
    }

    @Test func requestRunWithOnlyPrivacyConfirmsWithoutClearingAnything() async {
        let cleared = TestBox<[PrivacyRemovalRequest]>([])
        let vm = await scannedViewModel(plan: Self.privacyOnlyPlan, clearedRequests: cleared)
        vm.toggleBrowserPrivacy(Self.cookies)

        await vm.requestRun()

        #expect(vm.isConfirmingRun, "a permanent browser-data clear must confirm first")
        #expect(cleared.value.isEmpty, "no browser data is cleared until the user confirms")
        #expect(!vm.isRunDiscVisible, "the disc hides behind the sheet")
        guard case .results = vm.phase else {
            Issue.record("expected to stay on the results feed, got \(vm.phase)")
            return
        }
    }

    @Test func confirmRunClearsTheCheckedCategories() async {
        let cleared = TestBox<[PrivacyRemovalRequest]>([])
        let vm = await scannedViewModel(plan: Self.privacyOnlyPlan, clearedRequests: cleared)
        vm.toggleBrowserPrivacy(Self.cookies)

        await vm.requestRun()
        await vm.confirmRun()

        #expect(!vm.isConfirmingRun)
        #expect(cleared.value == [PrivacyRemovalRequest(browser: .safari, category: .cookies, scope: .wholeCategory)])
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    @Test func cancelRunLeavesTheBrowserDataAlone() async {
        let cleared = TestBox<[PrivacyRemovalRequest]>([])
        let vm = await scannedViewModel(plan: Self.privacyOnlyPlan, clearedRequests: cleared)
        vm.toggleBrowserPrivacy(Self.cookies)

        await vm.requestRun()
        vm.cancelRun()

        #expect(!vm.isConfirmingRun)
        #expect(cleared.value.isEmpty, "cancel leaves the browsers untouched")
        #expect(vm.isRunDiscVisible, "the disc returns after cancel")
    }

    // MARK: - Nothing checked skips the sheet

    @Test func uncheckedPrivacyRunsTrashSafeWorkWithoutConfirming() async {
        let cleared = TestBox<[PrivacyRemovalRequest]>([])
        let recycled = TestBox<[URL]>([])
        let vm = await scannedViewModel(
            plan: Self.privacyAndDuplicatesPlan,
            clearedRequests: cleared,
            recycled: recycled
        )

        #expect(!vm.runIncludesPermanentDelete, "nothing is pre-selected, so only the Trash-safe copy is left")
        await vm.requestRun()

        #expect(!vm.isConfirmingRun, "no irreversible step, so no sheet")
        #expect(cleared.value.isEmpty, "an unchecked category is never cleared")
        #expect(recycled.value == [URL(fileURLWithPath: "/Downloads/copy")], "the duplicate copy still runs on one tap")
        guard case .done = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
    }

    @Test func uncheckingTheLastCategoryDropsTheSheet() async {
        let vm = await scannedViewModel(plan: Self.privacyAndDuplicatesPlan)
        vm.toggleBrowserPrivacy(Self.cookies)
        vm.toggleBrowserPrivacy(Self.cookies)

        #expect(!vm.runIncludesPermanentDelete, "a category checked then unchecked is not work the run will do")
    }

    // MARK: - Sheet summary

    @Test func privacyLineIsFlaggedPermanentAndSaysSo() async throws {
        let vm = await scannedViewModel(plan: Self.privacyAndDuplicatesPlan)
        vm.toggleBrowserPrivacy(Self.cookies)
        vm.toggleBrowserPrivacy(Self.cachedFiles)
        let summary = vm.runActionSummary

        let privacyLine = try #require(summary.first { $0.kind == .browserPrivacy })
        #expect(privacyLine.isPermanent, "the sheet must mark browser-data clearing as irreversible")
        #expect(privacyLine.text == "Permanently clears 2 browser data items")
        #expect(summary.first { $0.kind == .duplicates }?.isPermanent == false, "duplicates still go to the Trash")
    }
}
