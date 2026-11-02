// CleanupFlowTests.swift
// Pins the Cleanup section's clean flow: what a one-click Clean may touch, what is pre-checked, what the confirmation says, and that a clean runs once, can be stopped, and reports honestly.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite("Cleanup flow")
@MainActor
struct CleanupFlowTests {

    private func file(_ path: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: category)
    }

    private func makeViewModel(
        _ items: [ScannedFile],
        deleter: @escaping SystemJunkViewModel.Deleter = { _, _ in JunkRemovalReport() }
    ) async -> SystemJunkViewModel {
        let vm = SystemJunkViewModel(scanner: { _ in ScanResult(items: items) }, deleter: deleter)
        await vm.scan()
        return vm
    }

    // MARK: - One-click Clean

    @Test("The System Junk card's Clean leaves opt-in user data alone")
    func directCleanSparesUserData() async {
        let deleted = TestBox<[ScannedFile]>([])
        let vm = await makeViewModel(
            [
                file("/Users/me/Library/Caches/a", 10, .userCache),
                file("/Users/me/Library/Application Support/MobileSync/Backup/UDID", 90_000, .iosBackups),
                file("/Users/me/Library/Mail Downloads/contract.pdf", 500, .mailAttachments),
            ],
            deleter: { files, _ in deleted.withLock { $0 = files }; return JunkRemovalReport() }
        )

        await vm.clean(categories: Set(CleanupGroup.systemJunk.categories))

        #expect(deleted.value.map(\.category) == [.userCache])
    }

    @Test("Clean on a card with nothing safe to remove does nothing")
    func directCleanWithNothingSafeIsANoOp() async {
        let calls = TestBox(0)
        let vm = await makeViewModel(
            [file("/Users/me/Library/Mail Downloads/contract.pdf", 500, .mailAttachments)],
            deleter: { _, _ in calls.withLock { $0 += 1 }; return JunkRemovalReport() }
        )

        await vm.clean(categories: [.mailAttachments])

        #expect(calls.value == 0)
        if case .preview = vm.phase {} else { Issue.record("expected the preview to stay up, got \(vm.phase)") }
    }

    // MARK: - Default selection

    @Test("Saved Xcode archives and document history aren't pre-checked; rebuildable Xcode data is")
    func safeDefaultsSpareIrreplaceable() async {
        let archive = file("/Users/me/Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive", 900, .xcodeJunk)
        let derived = file("/Users/me/Library/Developer/Xcode/DerivedData/App/x.o", 40, .xcodeJunk)
        let version = file(kDocumentVersionsRevisionsPath + "/501/1/v.txt", 90, .documentVersions)

        let seed = await ScanSelectionSeed.safeDefaults(from: ScanResult(items: [archive, derived, version]))

        #expect(seed.urls == [derived.url])
        #expect(seed.totalBytes == 40)
        #expect(seed.countByCategory[.xcodeJunk] == 1)
    }

    @Test("A card's Review doesn't pre-check archives either")
    func cardReviewSparesArchives() async {
        let archive = file("/Users/me/Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive", 900, .xcodeJunk)
        let derived = file("/Users/me/Library/Developer/Xcode/DerivedData/App/x.o", 40, .xcodeJunk)
        let vm = await makeViewModel([archive, derived])

        await vm.selectOnly(categories: [.xcodeJunk])

        #expect(vm.selectedURLs == [derived.url])
    }

    // MARK: - Running a clean

    @Test("Two quick clicks delete once")
    func doubleCleanDeletesOnce() async {
        let calls = TestBox(0)
        let vm = await makeViewModel(
            [file("/Users/me/Library/Caches/a", 10, .userCache)],
            deleter: { _, _ in calls.withLock { $0 += 1 }; return JunkRemovalReport() }
        )

        async let first: Void = vm.clean()
        async let second: Void = vm.clean()
        _ = await (first, second)

        #expect(calls.value == 1)
    }

    @Test("A clean leaves the preview before its first suspension, closing every other path into it")
    func cleanLeavesPreviewImmediately() async {
        let vm = await makeViewModel([file("/Users/me/Library/Caches/a", 10, .userCache)])

        async let cleaning: Void = vm.clean()
        await Task.yield()
        let phaseDuringClean = vm.phase
        await cleaning

        if case .preview = phaseDuringClean { Issue.record("the preview was still up while a clean was starting") }
    }

    @Test("Start Over while a clean is still choosing its files cancels the deletion")
    func startOverCancelsClean() async {
        let calls = TestBox(0)
        let items = (0..<200_000).map { file("/Users/me/.Trash/\($0)", 1, .trash) }
        let vm = await makeViewModel(items, deleter: { _, _ in calls.withLock { $0 += 1 }; return JunkRemovalReport() })

        let clean = Task { await vm.clean(categories: [.trash]) }
        await Task.yield()
        vm.scanAgain()
        await clean.value

        #expect(calls.value == 0)
        #expect(vm.phase == .idle)
    }

    @Test("A clean with no matching files returns to the preview")
    func emptyCleanReturnsToPreview() async {
        let vm = await makeViewModel([file("/Users/me/Library/Caches/a", 10, .userCache)])

        await vm.clean(categories: [.trash])

        if case .preview = vm.phase {} else { Issue.record("expected the preview, got \(vm.phase)") }
    }

    @Test("A partial clean lands on the report")
    func partialCleanCompletes() async {
        let report = JunkRemovalReport(bytesFreed: 5, bytesMovedToTrash: 7, removedCount: 2, failedCount: 1)
        let vm = await makeViewModel(
            [file("/Users/me/Library/Caches/a", 10, .userCache)],
            deleter: { _, _ in report }
        )

        await vm.clean()

        #expect(vm.phase == .complete(report))
    }

    @Test("A clean where nothing could be removed lands on the failure screen")
    func allFailedCleanFails() async {
        let vm = await makeViewModel(
            [file("/Library/Caches/a", 10, .systemCache)],
            deleter: { _, _ in JunkRemovalReport(failedCount: 1) }
        )

        await vm.clean()

        guard case .failed(let stage, _) = vm.phase else {
            Issue.record("expected the failure screen, got \(vm.phase)")
            return
        }
        #expect(stage == .cleaning)
    }

    @Test("A clean stopped before removing anything returns to the preview")
    func stoppedBeforeAnythingReturnsToPreview() async {
        let vm = await makeViewModel(
            [file("/Users/me/Library/Caches/a", 10, .userCache)],
            deleter: { _, _ in JunkRemovalReport(wasCancelled: true) }
        )

        await vm.clean()

        if case .preview = vm.phase {} else { Issue.record("expected the preview, got \(vm.phase)") }
    }

    @Test("A clean stopped partway lands on the report, not the now-stale preview")
    func stoppedPartwayCompletes() async {
        let report = JunkRemovalReport(bytesMovedToTrash: 4, removedCount: 1, wasCancelled: true)
        let vm = await makeViewModel(
            [file("/Users/me/Library/Caches/a", 10, .userCache)],
            deleter: { _, _ in report }
        )

        await vm.clean()

        #expect(vm.phase == .complete(report))
    }

    @Test("beginClean runs the clean, and cancelClean reaches the deleter")
    func beginAndCancel() async {
        let gate = TestBox(false)
        let observedCancel = TestBox(false)
        let vm = await makeViewModel(
            [file("/Users/me/Library/Caches/a", 10, .userCache)],
            deleter: { _, _ in
                gate.withLock { $0 = true }
                while !Task.isCancelled { await Task.yield() }
                observedCancel.withLock { $0 = true }
                return JunkRemovalReport(wasCancelled: true)
            }
        )

        vm.beginClean()
        #expect(await pollUntil { gate.value })
        vm.cancelClean()

        #expect(await pollUntil { observedCancel.value })
        #expect(await pollUntil { if case .preview = vm.phase { true } else { false } })
    }

    @Test("Progress reaches the screen, and only while cleaning")
    func progressReachesTheScreen() async {
        let vm = await makeViewModel(
            [
                file("/Users/me/Library/Caches/a", 1, .userCache),
                file("/Users/me/Library/Caches/b", 1, .userCache),
            ],
            deleter: { files, progress in
                progress(files.count)
                try? await Task.sleep(for: .milliseconds(50))
                return JunkRemovalReport(removedCount: files.count)
            }
        )

        async let cleaning: Void = vm.clean()
        #expect(await pollUntil { vm.cleanedItemCount == 2 })
        #expect(vm.cleanTotalCount == 2)
        await cleaning
    }

    // MARK: - Confirmation

    @Test("The confirmation describes the current selection, split by what is permanent")
    func selectionConfirmation() async {
        let vm = await makeViewModel([
            file("/Users/me/.Trash/old.dmg", 1_000, .trash),
            file("/Users/me/Library/Caches/a", 200, .userCache),
        ])

        let confirmation = vm.selectionConfirmation

        #expect(confirmation.itemCount == 2)
        #expect(confirmation.totalBytes == 1_200)
        #expect(confirmation.permanentBytes == 1_000)
    }

    @Test("A card's confirmation counts only what its Clean would really remove")
    func directCleanConfirmation() async throws {
        let vm = await makeViewModel([
            file("/Users/me/Library/Caches/a", 200, .userCache),
            file("/Users/me/Library/Application Support/MobileSync/Backup/UDID", 90_000, .iosBackups),
        ])

        let confirmation = try #require(await vm.directCleanConfirmation(categories: Set(CleanupGroup.systemJunk.categories)))

        #expect(confirmation.itemCount == 1)
        #expect(confirmation.totalBytes == 200)
        #expect(confirmation.permanentBytes == 0)
    }

    @Test("A card with nothing safe to remove has no confirmation to show")
    func directCleanConfirmationEmpty() async {
        let vm = await makeViewModel([file("/Users/me/Library/Mail Downloads/a.pdf", 5, .mailAttachments)])

        #expect(await vm.directCleanConfirmation(categories: [.mailAttachments]) == nil)
    }

    @Test(
        "The confirmation says what is permanent",
        arguments: [
            (Int64(1_000), Int64(1_000), "permanently"),
            (Int64(1_000), Int64(400), "permanently"),
            (Int64(1_000), Int64(0), "Trash"),
        ]
    )
    func confirmationCopy(total: Int64, permanent: Int64, expected: String) {
        let confirmation = CleanupConfirmation(itemCount: 3, totalBytes: total, permanentBytes: permanent)
        #expect(confirmation.message.contains(expected))
    }

    @Test("A partly permanent clean names both destinations")
    func confirmationCopyMixed() {
        let confirmation = CleanupConfirmation(itemCount: 3, totalBytes: 1_000, permanentBytes: 400)
        #expect(confirmation.message.contains("permanently"))
        #expect(confirmation.message.contains("Trash"))
    }

    // MARK: - Review All

    @Test("Review All opens empty the first time and keeps the user's picks after that")
    func reviewAllKeepsEdits() async {
        let a = file("/Users/me/Library/Caches/a", 10, .userCache)
        let vm = await makeViewModel([a])

        vm.prepareReviewAll()
        #expect(vm.selectedURLs.isEmpty)

        vm.toggleSelection(a)
        vm.prepareReviewAll()
        #expect(vm.selectedURLs == [a.url])
    }

    @Test("A card's Review re-seeding counts as no edit, so Review All can clear it")
    func reviewAllClearsAReseed() async {
        let a = file("/Users/me/Library/Caches/a", 10, .userCache)
        let vm = await makeViewModel([a])
        vm.toggleSelection(a)

        await vm.selectOnly(categories: [.userCache])
        vm.prepareReviewAll()

        #expect(vm.selectedURLs.isEmpty)
    }

    // MARK: - Staying in step with Smart Scan

    @Test("Results Smart Scan has acted on are dropped from the preview")
    func stalePreviewIsDiscarded() async {
        let vm = await makeViewModel([file("/Users/me/Library/Caches/a", 10, .userCache)])

        vm.discardStalePreview()

        #expect(vm.phase == .idle)
    }

    @Test("Only a preview is discarded; a report on screen stays")
    func staleDiscardLeavesReports() async {
        let vm = await makeViewModel([file("/Users/me/Library/Caches/a", 10, .userCache)])
        await vm.clean()
        let shown = vm.phase

        vm.discardStalePreview()

        #expect(vm.phase == shown)
    }
}
