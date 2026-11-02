// MyClutterReviewFlowTests.swift
// Drives My Clutter's review-and-remove flow: honest scan failures, the chosen folder's reach, what a review opens with, which copy is kept, and how removals report failure and survive a restart.

import Foundation
import Testing
@testable import VaderCleanerCore

private func file(_ path: String, size: Int64 = 10) -> ScannedFile {
    ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
}

private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

private enum SubScanFailure: Error { case boom }

@MainActor
private func makeViewModel(
    duplicates: [DuplicateGroup] = [],
    similar: [SimilarImageGroup] = [],
    largeOld: [ScannedFile] = [],
    downloads: [DownloadItem] = [],
    deleter: @escaping ([URL]) async -> Set<URL> = { Set($0) }
) -> MyClutterViewModel {
    MyClutterViewModel(
        duplicateScan: { _ in duplicates },
        similarScan: { _ in similar },
        largeOldScan: { _ in largeOld },
        downloadsScan: { _ in downloads },
        deleter: deleter
    )
}

// MARK: - Scan failures

@Suite @MainActor struct MyClutterScanFailureTests {

    /// With nothing to show, one failed sub-scan means part of the Mac went
    /// unchecked, so "Nothing to clean up" would be a false all-clear.
    @Test func aFailedSubScanWithNothingElseFoundIsAFailure() async {
        let vm = MyClutterViewModel(
            duplicateScan: { _ in throw SubScanFailure.boom },
            similarScan: { _ in [] },
            largeOldScan: { _ in [] },
            downloadsScan: { _ in [] },
            deleter: { Set($0) }
        )

        await vm.scan()

        guard case .failed = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
    }

    @Test func aPickedFolderThatIsGoneFailsTheScanNamingIt() async throws {
        let defaults = try #require(UserDefaults(suiteName: "MyClutterScanFailureTests-\(UUID().uuidString)"))
        let scope = MyClutterScanScopeStore(defaults: defaults)
        scope.selectFolder(url("/Volumes/NoSuchDrive-\(UUID().uuidString)/Photos"))
        let vm = MyClutterViewModel.live(exclusions: ExclusionsStore(defaults: defaults), scanScope: scope)

        await vm.scan()

        guard case .failed(let message) = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(message.contains("Photos"))
    }

    /// A folder with nothing in it is a real answer, not a failure — and picking
    /// it means the scan looked nowhere else, `~/Downloads` included.
    @Test func aPickedFolderIsTheOnlyPlaceLooked() async throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let defaults = try #require(UserDefaults(suiteName: "MyClutterScanFailureTests-\(UUID().uuidString)"))
        let scope = MyClutterScanScopeStore(defaults: defaults)
        scope.selectFolder(root)
        let vm = MyClutterViewModel.live(exclusions: ExclusionsStore(defaults: defaults), scanScope: scope)

        await vm.scan()

        #expect(vm.phase == .empty)
        #expect(vm.downloads.isEmpty)
    }
}

// MARK: - Downloads within the chosen folder

@Suite struct MyClutterDownloadsRootTests {
    private let downloads = url("/Users/me/Downloads")

    private func root(picked: String?) -> URL? {
        MyClutterViewModel.downloadsRoot(scanRoots: picked.map { [url($0)] }, downloads: downloads)
    }

    @Test func theHomeScopeWalksDownloads() {
        #expect(root(picked: nil) == downloads)
    }

    @Test func anUnrelatedFolderWalksNoDownloads() {
        #expect(root(picked: "/Users/me/Projects") == nil)
    }

    @Test func aSiblingWithASharedPrefixWalksNoDownloads() {
        #expect(root(picked: "/Users/me/Downloads Old") == nil)
    }

    @Test func downloadsItselfOrAnAncestorWalksDownloads() {
        #expect(root(picked: "/Users/me/Downloads") == downloads)
        #expect(root(picked: "/Users") == downloads)
        #expect(root(picked: "/") == downloads)
    }

    @Test func aFolderInsideDownloadsWalksOnlyThatFolder() {
        #expect(root(picked: "/Users/me/Downloads/Installers") == url("/Users/me/Downloads/Installers"))
    }
}

// MARK: - What a review opens with

@Suite @MainActor struct MyClutterBeginReviewTests {
    private let group = DuplicateGroup(files: [file("/a/orig.txt"), file("/a/copy.txt")])
    private let similar = SimilarImageGroup(files: [file("/p/a.jpg", size: 50), file("/p/b.jpg", size: 40)])
    private let large = file("/big/a.mov", size: 100)

    private func scanned() async -> MyClutterViewModel {
        let vm = makeViewModel(duplicates: [group], similar: [similar], largeOld: [large])
        await vm.scan()
        return vm
    }

    @Test func reviewAllOpensWithNothingChecked() async {
        let vm = await scanned()
        vm.beginReview(of: nil)
        #expect(vm.selectedURLs.isEmpty)
        #expect(vm.totalSelectedSize == 0)
        #expect(vm.selectedCount(in: .duplicates) == 0)
    }

    @Test func theDuplicatesCardChecksItsCopies() async {
        let vm = await scanned()
        vm.beginReview(of: .duplicates)
        #expect(vm.selectedURLs == [url("/a/copy.txt")])
        #expect(vm.selectedBytes(in: .duplicates) == 10)
    }

    /// Similar images look alike but are different files: Trashing one always
    /// loses something, so nothing is checked for the user.
    @Test(arguments: [MyClutterCategory.similar, .largeOld, .downloads])
    func otherCardsOpenUnchecked(_ category: MyClutterCategory) async {
        let vm = await scanned()
        vm.beginReview(of: category)
        #expect(vm.selectedURLs.isEmpty)
    }

    @Test func reopeningKeepsWhatTheUserUnchecked() async {
        let vm = await scanned()
        vm.beginReview(of: .duplicates)
        vm.toggleSelection(url: url("/a/copy.txt"))

        vm.beginReview(of: .duplicates)

        #expect(vm.selectedURLs.isEmpty, "A copy the user chose to keep must not come back checked")
    }

    @Test func movingBetweenCardsKeepsEarlierChoices() async {
        let vm = await scanned()
        vm.beginReview(of: .largeOld)
        vm.toggleSelection(url: large.url)

        vm.beginReview(of: .duplicates)
        vm.beginReview(of: nil)

        #expect(vm.selectedURLs == [large.url, url("/a/copy.txt")])
    }

    @Test func reviewAllThenEditingDuplicatesStopsTheCardReseeding() async {
        let vm = await scanned()
        vm.beginReview(of: nil)
        vm.setSelection([url("/a/copy.txt")], selected: true)
        vm.setSelection([url("/a/copy.txt")], selected: false)

        vm.beginReview(of: .duplicates)

        #expect(vm.selectedURLs.isEmpty)
    }

    @Test func aNewScanStartsTheFlowOver() async {
        let vm = await scanned()
        vm.beginReview(of: .duplicates)
        vm.toggleSelection(url: url("/a/copy.txt"))

        await vm.scan()
        vm.beginReview(of: .duplicates)

        #expect(vm.selectedURLs == [url("/a/copy.txt")])
    }
}

// MARK: - Choosing which copy to keep

@Suite @MainActor struct MyClutterKeepCopyTests {
    private let a = file("/a/a.txt")
    private let b = file("/a/b.txt")
    private let c = file("/a/c.txt")

    private func scanned() async -> MyClutterViewModel {
        let vm = makeViewModel(duplicates: [DuplicateGroup(files: [a, b, c])])
        await vm.scan()
        vm.beginReview(of: .duplicates)
        return vm
    }

    @Test func aKeptFileHasNoEffectWhenToggled() async {
        let vm = await scanned()
        vm.toggleSelection(url: a.url)
        #expect(!vm.isSelected(a.url))
    }

    @Test func keepingACheckedCopySwapsItWithTheOriginal() async {
        let vm = await scanned()

        vm.keep(b.url, in: .duplicates)

        #expect(vm.duplicateGroups.first?.original == b)
        #expect(vm.duplicateCopies.map(\.url) == [a.url, c.url])
        #expect(vm.selectedURLs == [a.url, c.url], "The file to remove is now the old original")
        #expect(vm.selectedCount(in: .duplicates) == 2)
        #expect(vm.selectedBytes(in: .duplicates) == 20)
    }

    @Test func keepingAnUncheckedCopyChecksNothingNew() async {
        let vm = await scanned()
        vm.toggleSelection(url: b.url)

        vm.keep(b.url, in: .duplicates)

        #expect(vm.selectedURLs == [c.url])
    }

    @Test func theOldOriginalCanBeCheckedAndTheNewOneCannot() async {
        let vm = await scanned()
        vm.toggleSelection(url: b.url)
        vm.keep(b.url, in: .duplicates)

        vm.toggleSelection(url: a.url)
        vm.toggleSelection(url: b.url)

        #expect(vm.isSelected(a.url))
        #expect(!vm.isSelected(b.url))
    }

    /// A removal must take the file the user ended up choosing, and spare the
    /// one they kept.
    @Test func removingAfterKeepSparesTheChosenFile() async {
        let vm = await scanned()
        vm.keep(b.url, in: .duplicates)

        await vm.deleteSelected(in: Set(vm.duplicateCopies.map(\.url)))

        #expect(vm.duplicateGroups.isEmpty)
        #expect(vm.selectedURLs.isEmpty)
    }

    @Test func keepingUnchecksAFileListedInAnotherCategoryToo() async {
        let vm = makeViewModel(duplicates: [DuplicateGroup(files: [a, b])], largeOld: [b])
        await vm.scan()
        vm.beginReview(of: .duplicates)

        vm.keep(b.url, in: .duplicates)

        #expect(!vm.isSelected(b.url))
        #expect(vm.selectedCount(in: .largeOld) == 0)
        vm.toggleSelection(url: b.url)
        #expect(vm.isSelected(b.url), "It is still removable from Large & Old")
    }

    @Test func keepWorksOnSimilarGroups() async {
        let vm = makeViewModel(similar: [SimilarImageGroup(files: [a, b])])
        await vm.scan()

        vm.keep(b.url, in: .similar)

        #expect(vm.similarGroups.first?.original == b)
        #expect(vm.similarCopies.map(\.url) == [a.url])
    }

    @Test func keepingTheCurrentOriginalOrAStrangerChangesNothing() async {
        let vm = await scanned()
        let before = vm.duplicateGroups

        vm.keep(a.url, in: .duplicates)
        vm.keep(url("/nowhere"), in: .duplicates)

        #expect(vm.duplicateGroups == before)
    }
}

// MARK: - Removal

@Suite @MainActor struct MyClutterRemovalTests {
    private let a = file("/big/a.mov")
    private let b = file("/big/b.mov")

    @Test func aFullSuccessReportsNoFailure() async {
        let vm = makeViewModel(largeOld: [a, b])
        await vm.scan()
        vm.setSelection([a.url, b.url], selected: true)

        await vm.deleteSelected(in: [a.url, b.url])

        #expect(vm.removalFailureCount == 0)
    }

    @Test func aPartialFailureCountsWhatStayed() async {
        let moved = a.url
        let vm = makeViewModel(largeOld: [a, b], deleter: { _ in [moved] })
        await vm.scan()
        vm.setSelection([a.url, b.url], selected: true)

        await vm.deleteSelected(in: [a.url, b.url])

        #expect(vm.removalFailureCount == 1)
        #expect(vm.largeOldFiles == [b])
        #expect(vm.isSelected(b.url), "The survivor stays checked for a retry")
    }

    @Test func aTotalFailureIsReported() async {
        let vm = makeViewModel(largeOld: [a, b], deleter: { _ in [] })
        await vm.scan()
        vm.setSelection([a.url, b.url], selected: true)

        await vm.deleteSelected(in: [a.url, b.url])

        #expect(vm.removalFailureCount == 2)
        #expect(vm.largeOldFiles.count == 2)
    }

    @Test func theFailureClearsOnTheNextSelectionChange() async {
        let vm = makeViewModel(largeOld: [a, b], deleter: { _ in [] })
        await vm.scan()
        vm.setSelection([a.url], selected: true)
        await vm.deleteSelected(in: [a.url])
        #expect(vm.removalFailureCount == 1)

        vm.toggleSelection(url: b.url)

        #expect(vm.removalFailureCount == 0)
    }

    @Test func aSecondRemoveWhileOneIsRunningDoesNothing() async {
        let gate = SuspendingCallGate()
        let calls = TestBox(0)
        let vm = makeViewModel(largeOld: [a, b], deleter: { urls in
            calls.value += 1
            await gate.hold()
            return Set(urls)
        })
        await vm.scan()
        vm.setSelection([a.url], selected: true)

        let first = Task { await vm.deleteSelected(in: [a.url]) }
        #expect(await pollUntil { gate.isHolding })
        #expect(vm.isRemoving)

        await vm.deleteSelected(in: [a.url])
        #expect(calls.value == 1)

        gate.open()
        await first.value
        #expect(!vm.isRemoving)
    }

    @Test func aRemovalEndingAfterStartOverLeavesTheIntroAlone() async {
        let gate = SuspendingCallGate()
        let vm = makeViewModel(largeOld: [a], deleter: { urls in
            await gate.hold()
            return Set(urls)
        })
        await vm.scan()
        vm.setSelection([a.url], selected: true)
        let removal = Task { await vm.deleteSelected(in: [a.url]) }
        #expect(await pollUntil { gate.isHolding })

        vm.scanAgain()
        gate.open()
        await removal.value

        #expect(vm.phase == .idle)
    }

    @Test func aRemovalEndingDuringARescanLeavesTheScanAlone() async {
        let removalGate = SuspendingCallGate()
        let scanGate = SuspendingCallGate()
        let scanned = TestBox(0)
        let target = a
        let vm = MyClutterViewModel(
            duplicateScan: { _ in [] },
            similarScan: { _ in [] },
            largeOldScan: { _ in
                scanned.value += 1
                if scanned.value > 1 { await scanGate.hold() }
                return [target]
            },
            downloadsScan: { _ in [] },
            deleter: { urls in
                await removalGate.hold()
                return Set(urls)
            }
        )
        await vm.scan()
        vm.setSelection([a.url], selected: true)
        let removal = Task { await vm.deleteSelected(in: [target.url]) }
        #expect(await pollUntil { removalGate.isHolding })

        vm.scanAgain()
        let rescan = Task { await vm.scan() }
        #expect(await pollUntil { scanGate.isHolding })
        removalGate.open()
        await removal.value

        #expect(vm.phase == .scanning)

        scanGate.open()
        await rescan.value
        #expect(vm.phase == .results)
        #expect(vm.largeOldFiles == [target], "The new scan's results are untouched by the old removal")
    }

    /// `scanAgain` must also stop a scan still running, or its late results would
    /// pull the screen away from the intro.
    @Test func aScanEndingAfterStartOverLeavesTheIntroAlone() async {
        let gate = SuspendingCallGate()
        let target = a
        let vm = MyClutterViewModel(
            duplicateScan: { _ in [] },
            similarScan: { _ in [] },
            largeOldScan: { _ in
                await gate.hold()
                return [target]
            },
            downloadsScan: { _ in [] },
            deleter: { Set($0) }
        )
        let scan = Task { await vm.scan() }
        #expect(await pollUntil { gate.isHolding })

        vm.scanAgain()
        gate.open()
        await scan.value

        #expect(vm.phase == .idle)
        #expect(vm.largeOldFiles.isEmpty)
    }
}

// MARK: - Manager pane resolution

@Suite struct MyClutterResolvedGroupTests {
    private let first = DuplicateGroup(files: [file("/a/1"), file("/b/1")])
    private let second = DuplicateGroup(files: [file("/a/2"), file("/b/2")])

    @Test func usesTheSelectedGroup() {
        #expect(MyClutterManagerModel.resolvedGroup(selectedID: second.id, in: [first, second]) == second)
    }

    @Test func aMissingSelectionFallsToTheFirstGroup() {
        #expect(MyClutterManagerModel.resolvedGroup(selectedID: nil, in: [first, second]) == first)
    }

    /// A stale ID — a removed group, or one from the other image category — must
    /// not read as "nothing to review" while groups remain.
    @Test func aStaleSelectionFallsToTheFirstGroup() {
        #expect(MyClutterManagerModel.resolvedGroup(selectedID: "/gone", in: [first, second]) == first)
    }

    @Test func noGroupsResolvesToNothing() {
        #expect(MyClutterManagerModel.resolvedGroup(selectedID: "/gone", in: [DuplicateGroup]()) == nil)
    }
}
