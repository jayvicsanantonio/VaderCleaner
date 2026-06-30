// MyClutterViewModelTests.swift
// Drives the My Clutter orchestrator with injected scans: result aggregation, the smart default selection of redundant copies, selection math, deletion pruning, and the ScanCoordinating mapping.

import XCTest
@testable import VaderCleaner

@MainActor
final class MyClutterViewModelTests: XCTestCase {

    private func file(_ path: String, size: Int64) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .largeFile
        )
    }

    /// Builds a VM whose scans return fixed fixtures and whose deleter reports
    /// every requested URL as trashed.
    private func makeViewModel(
        duplicates: [DuplicateGroup] = [],
        similar: [SimilarImageGroup] = [],
        largeOld: [ScannedFile] = [],
        downloads: [DownloadItem] = [],
        deleted: ((Set<URL>) -> Void)? = nil
    ) -> MyClutterViewModel {
        MyClutterViewModel(
            duplicateScan: { _ in duplicates },
            similarScan: { _ in similar },
            largeOldScan: { _ in largeOld },
            downloadsScan: { _ in downloads },
            deleter: { urls in
                let set = Set(urls)
                deleted?(set)
                return set
            }
        )
    }

    func test_scanAggregatesResultsAndCount() async {
        let dup = DuplicateGroup(files: [file("/a/orig.txt", size: 10), file("/a/copy.txt", size: 10)])
        let sim = SimilarImageGroup(files: [file("/p/a.jpg", size: 50), file("/p/b.jpg", size: 40)])
        let large = [file("/big/movie.mov", size: 1000)]
        let dl = [DownloadItem(file: file("/d/app.dmg", size: 500), sourceApp: "Google Chrome")]
        let vm = makeViewModel(duplicates: [dup], similar: [sim], largeOld: large, downloads: dl)

        await vm.scan()

        XCTAssertEqual(vm.phase, .results)
        // 1 duplicate copy + 1 similar copy + 1 large + 1 download.
        XCTAssertEqual(vm.totalFileCount, 4)
        XCTAssertEqual(vm.duplicateReclaimableBytes, 10)
        XCTAssertEqual(vm.similarReclaimableBytes, 40)
        XCTAssertEqual(vm.largeOldBytes, 1000)
        XCTAssertEqual(vm.downloadsBytes, 500)
        XCTAssertEqual(vm.dominantDownloadSource, "Google Chrome")
    }

    func test_scanSelectsNothingByDefault() async {
        let dup = DuplicateGroup(files: [file("/a/orig.txt", size: 10), file("/a/copy.txt", size: 10)])
        let sim = SimilarImageGroup(files: [file("/p/a.jpg", size: 50), file("/p/b.jpg", size: 40)])
        let large = [file("/big/movie.mov", size: 1000)]
        let vm = makeViewModel(duplicates: [dup], similar: [sim], largeOld: large)

        await vm.scan()

        // A scan leaves every item unselected — Review opens with a clean slate.
        XCTAssertTrue(vm.selectedURLs.isEmpty)
        XCTAssertFalse(vm.isSelected(URL(fileURLWithPath: "/a/copy.txt")))
        XCTAssertFalse(vm.isSelected(URL(fileURLWithPath: "/p/b.jpg")))
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    func test_emptyWhenNothingFound() async {
        let vm = makeViewModel()
        await vm.scan()
        XCTAssertEqual(vm.phase, .empty)
        XCTAssertEqual(vm.totalFileCount, 0)
    }

    func test_toggleAndSetSelectionUpdateTotal() async {
        let large = [file("/big/a.mov", size: 100), file("/big/b.mov", size: 200)]
        let vm = makeViewModel(largeOld: large)
        await vm.scan()
        XCTAssertEqual(vm.totalSelectedSize, 0)

        vm.toggleSelection(url: URL(fileURLWithPath: "/big/a.mov"))
        XCTAssertEqual(vm.totalSelectedSize, 100)

        vm.setSelection([URL(fileURLWithPath: "/big/a.mov"), URL(fileURLWithPath: "/big/b.mov")], selected: true)
        XCTAssertEqual(vm.totalSelectedSize, 300)

        vm.setSelection([URL(fileURLWithPath: "/big/a.mov")], selected: false)
        XCTAssertEqual(vm.totalSelectedSize, 200)
    }

    // MARK: - Per-category selected totals (manager facet / footer)

    /// Toggling a file must move its bytes and count into its own category's
    /// running totals, leaving sibling categories untouched — so the manager's
    /// Large & Old "Selected" facet and per-category footer read O(1) instead of
    /// reducing over the (potentially huge) file list on every render.
    func test_selectedPerCategory_tracksTogglesPerCategory() async {
        let dup = DuplicateGroup(files: [file("/a/orig.txt", size: 10), file("/a/copy.txt", size: 10)])
        let large = [file("/big/a.mov", size: 100), file("/big/b.mov", size: 200)]
        let vm = makeViewModel(duplicates: [dup], largeOld: large)
        await vm.scan()

        vm.toggleSelection(url: URL(fileURLWithPath: "/big/a.mov"))
        vm.toggleSelection(url: URL(fileURLWithPath: "/a/copy.txt"))

        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 100)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 1)
        XCTAssertEqual(vm.selectedBytes(in: .duplicates), 10)
        XCTAssertEqual(vm.selectedCount(in: .duplicates), 1)
        XCTAssertEqual(vm.selectedBytes(in: .similar), 0)
        XCTAssertEqual(vm.selectedCount(in: .downloads), 0)

        vm.toggleSelection(url: URL(fileURLWithPath: "/big/a.mov")) // deselect
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 0)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 0)
        XCTAssertEqual(vm.selectedBytes(in: .duplicates), 10, "A sibling category is unaffected")
    }

    /// A file that belongs to two categories (e.g. a large file that is also a
    /// duplicate copy) must count toward both categories' totals — matching the
    /// manager's independent per-category facet reduces.
    func test_selectedPerCategory_fileInTwoCategoriesCountsInBoth() async {
        // The duplicate's redundant copy and a large file share a URL.
        let shared = "/x/shared.mov"
        let dup = DuplicateGroup(files: [file("/x/orig.mov", size: 50), file(shared, size: 50)])
        let large = [file(shared, size: 50)]
        let vm = makeViewModel(duplicates: [dup], largeOld: large)
        await vm.scan()

        vm.toggleSelection(url: URL(fileURLWithPath: shared))

        XCTAssertEqual(vm.selectedBytes(in: .duplicates), 50)
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 50)
        XCTAssertEqual(vm.selectedCount(in: .duplicates), 1)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 1)
    }

    /// `setSelection` (bulk Select/Deselect) keeps the per-category totals in sync.
    func test_selectedPerCategory_bulkSetSelection() async {
        let large = [file("/big/a.mov", size: 100), file("/big/b.mov", size: 200)]
        let vm = makeViewModel(largeOld: large)
        await vm.scan()

        vm.setSelection([URL(fileURLWithPath: "/big/a.mov"), URL(fileURLWithPath: "/big/b.mov")], selected: true)
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 300)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 2)

        vm.setSelection([URL(fileURLWithPath: "/big/a.mov")], selected: false)
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 200)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 1)
    }

    /// Deleting selected files must recompute the per-category totals from the
    /// survivors, never carry the trashed files' bytes forward.
    func test_selectedPerCategory_recomputedAfterDeletion() async {
        let large = [file("/big/a.mov", size: 100), file("/big/b.mov", size: 200)]
        let vm = makeViewModel(largeOld: large)
        await vm.scan()
        vm.setSelection([URL(fileURLWithPath: "/big/a.mov"), URL(fileURLWithPath: "/big/b.mov")], selected: true)

        await vm.deleteSelected(in: [URL(fileURLWithPath: "/big/a.mov")])

        // Only a.mov was deleted; b.mov stays selected.
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 200)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 1)
    }

    /// A fresh scan must drop the per-category totals so the facet never carries
    /// a previous run's selection forward.
    func test_selectedPerCategory_clearedOnScan() async {
        let large = [file("/big/a.mov", size: 100)]
        let vm = makeViewModel(largeOld: large)
        await vm.scan()
        vm.toggleSelection(url: URL(fileURLWithPath: "/big/a.mov"))
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 100)

        await vm.scan()
        XCTAssertEqual(vm.selectedBytes(in: .largeOld), 0)
        XCTAssertEqual(vm.selectedCount(in: .largeOld), 0)
    }

    func test_deleteSelectedPrunesSurvivorsAndSelection() async {
        let dup = DuplicateGroup(files: [file("/a/orig.txt", size: 10), file("/a/copy.txt", size: 10)])
        let large = [file("/big/movie.mov", size: 1000)]
        var trashed: Set<URL> = []
        let vm = makeViewModel(duplicates: [dup], largeOld: large) { trashed = $0 }

        await vm.scan()
        // Nothing is selected by default; select the duplicate copy and the
        // large file explicitly.
        vm.toggleSelection(url: URL(fileURLWithPath: "/a/copy.txt"))
        vm.toggleSelection(url: URL(fileURLWithPath: "/big/movie.mov"))
        XCTAssertEqual(vm.selectedURLs.count, 2)

        await vm.deleteSelected()

        XCTAssertEqual(trashed, [URL(fileURLWithPath: "/a/copy.txt"), URL(fileURLWithPath: "/big/movie.mov")])
        // The duplicate group loses its only copy → group drops; large file gone.
        XCTAssertTrue(vm.duplicateGroups.isEmpty)
        XCTAssertTrue(vm.largeOldFiles.isEmpty)
        XCTAssertEqual(vm.totalFileCount, 0)
        XCTAssertEqual(vm.phase, .empty)
        XCTAssertTrue(vm.selectedURLs.isEmpty)
    }

    func test_scanCoordinatingMapping() async {
        let vm = makeViewModel(largeOld: [file("/big/a.mov", size: 1)])
        XCTAssertEqual(vm.scanPresentation, .intro)
        await vm.scan()
        XCTAssertEqual(vm.scanPresentation, .results)
        vm.scanAgain()
        XCTAssertEqual(vm.scanPresentation, .intro)
    }
}
