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

    func test_scanPreselectsRedundantCopiesOnly() async {
        let dup = DuplicateGroup(files: [file("/a/orig.txt", size: 10), file("/a/copy.txt", size: 10)])
        let sim = SimilarImageGroup(files: [file("/p/a.jpg", size: 50), file("/p/b.jpg", size: 40)])
        let large = [file("/big/movie.mov", size: 1000)]
        let vm = makeViewModel(duplicates: [dup], similar: [sim], largeOld: large)

        await vm.scan()

        // The duplicate copy and the similar copy are pre-selected; the kept
        // originals and the large file are not.
        XCTAssertTrue(vm.isSelected(URL(fileURLWithPath: "/a/copy.txt")))
        XCTAssertTrue(vm.isSelected(URL(fileURLWithPath: "/p/b.jpg")))
        XCTAssertFalse(vm.isSelected(URL(fileURLWithPath: "/a/orig.txt")))
        XCTAssertFalse(vm.isSelected(URL(fileURLWithPath: "/big/movie.mov")))
        XCTAssertEqual(vm.totalSelectedSize, 50, "10 (dup copy) + 40 (similar copy)")
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

    func test_deleteSelectedPrunesSurvivorsAndSelection() async {
        let dup = DuplicateGroup(files: [file("/a/orig.txt", size: 10), file("/a/copy.txt", size: 10)])
        let large = [file("/big/movie.mov", size: 1000)]
        var trashed: Set<URL> = []
        let vm = makeViewModel(duplicates: [dup], largeOld: large) { trashed = $0 }

        await vm.scan()
        // Pre-selected: the duplicate copy. Also select the large file.
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
