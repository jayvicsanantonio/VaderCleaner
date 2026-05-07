// LargeOldFilesViewModelTests.swift
// Tests the LargeOldFilesViewModel state machine, sort order, selection set, and deleteSelected — driven through injected fake scanner and deleter closures so no real filesystem is touched.

import XCTest
@testable import VaderCleaner

@MainActor
final class LargeOldFilesViewModelTests: XCTestCase {

    // MARK: - Initial state

    /// First appearance lands on `.idle` with an empty selection so the view
    /// renders its "Scan" CTA, not a stale results table.
    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.selectedURLs.isEmpty)
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Scan transitions

    /// A successful scan with at least one file lands in `.results` carrying
    /// the scanner's output — the phase carries the displayable list rather
    /// than forcing the view to query a separate property.
    func test_scan_withResultsTransitionsToResults() async {
        let files = [
            makeFile(name: "a.bin", size: 200, accessDaysAgo: 10, category: .largeFile),
            makeFile(name: "b.bin", size: 100, accessDaysAgo: 365, category: .oldFile)
        ]
        let vm = makeViewModel(scanner: { files })

        await vm.scan()

        if case .results(let returned) = vm.phase {
            XCTAssertEqual(returned.count, 2)
        } else {
            XCTFail("Expected .results, got \(vm.phase)")
        }
    }

    /// An empty scan must surface `.empty` rather than an empty `.results` —
    /// the view has dedicated copy for "Nothing found" and rendering a blank
    /// table would feel like the scan failed.
    func test_scan_withNoResultsTransitionsToEmpty() async {
        let vm = makeViewModel(scanner: { [] })

        await vm.scan()

        XCTAssertEqual(vm.phase, .empty)
    }

    /// Throwing scanner must surface `.failed` — never leave the user stuck
    /// on the spinner.
    func test_scan_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(scanner: { throw BoomError() })

        await vm.scan()

        if case .failed = vm.phase {} else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Default sort

    /// Default sort order must be size-descending so the first row is "the
    /// biggest thing on disk you forgot about" — the entire reason the user
    /// opened this feature.
    func test_displayedFiles_defaultSortIsSizeDescending() async {
        let files = [
            makeFile(name: "small", size: 100, accessDaysAgo: 1, category: .largeFile),
            makeFile(name: "huge",  size: 10_000, accessDaysAgo: 1, category: .largeFile),
            makeFile(name: "mid",   size: 1_000, accessDaysAgo: 1, category: .largeFile)
        ]
        let vm = makeViewModel(scanner: { files })

        await vm.scan()

        XCTAssertEqual(vm.sortOrder, .sizeDescending)
        XCTAssertEqual(vm.displayedFiles.map(\.size), [10_000, 1_000, 100])
    }

    /// Switching to date-ascending must reorder by oldest-access-first. The
    /// VM does the sort itself (rather than handing a `KeyPathComparator` to
    /// SwiftUI's `Table`) so the same ordering applies to the selection-set
    /// helpers and to any future export path.
    func test_displayedFiles_canSortByLastAccessDateAscending() async {
        let files = [
            makeFile(name: "recent",  size: 100, accessDaysAgo: 1,    category: .largeFile),
            makeFile(name: "ancient", size: 100, accessDaysAgo: 1_000, category: .oldFile),
            makeFile(name: "mid",     size: 100, accessDaysAgo: 100,  category: .oldFile)
        ]
        let vm = makeViewModel(scanner: { files })
        await vm.scan()

        vm.sortOrder = .dateAscending

        XCTAssertEqual(vm.displayedFiles.map(\.url.lastPathComponent),
                       ["ancient", "mid", "recent"])
    }

    /// Files with `nil` access date sort *last* under either date order so
    /// they don't crowd out the meaningful entries — they're displayed but
    /// can't be reasoned about by age.
    func test_displayedFiles_filesWithoutAccessDateSortLast() async {
        let withDate = makeFile(name: "dated", size: 100, accessDaysAgo: 200, category: .oldFile)
        let undated = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-vm/undated"),
            size: 100,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .largeFile
        )
        let vm = makeViewModel(scanner: { [undated, withDate] })
        await vm.scan()

        vm.sortOrder = .dateAscending
        XCTAssertEqual(vm.displayedFiles.map(\.url.lastPathComponent), ["dated", "undated"])

        vm.sortOrder = .dateDescending
        XCTAssertEqual(vm.displayedFiles.map(\.url.lastPathComponent), ["dated", "undated"])
    }

    // MARK: - Selection

    /// `totalSelectedSize` must reflect only currently-selected URLs and
    /// update on every toggle — the view binds it to the "Delete N items
    /// (X.X MB)" footer label.
    func test_toggleSelection_updatesTotalSelectedSize() async {
        let a = makeFile(name: "a", size: 100, accessDaysAgo: 1, category: .largeFile)
        let b = makeFile(name: "b", size: 250, accessDaysAgo: 1, category: .largeFile)
        let vm = makeViewModel(scanner: { [a, b] })
        await vm.scan()

        XCTAssertEqual(vm.totalSelectedSize, 0)

        vm.toggleSelection(a)
        XCTAssertEqual(vm.totalSelectedSize, 100)
        XCTAssertTrue(vm.isSelected(a))

        vm.toggleSelection(b)
        XCTAssertEqual(vm.totalSelectedSize, 350)

        vm.toggleSelection(a)
        XCTAssertEqual(vm.totalSelectedSize, 250)
        XCTAssertFalse(vm.isSelected(a))
    }

    // MARK: - Delete

    /// `deleteSelected()` hands the deleter only the currently-selected files
    /// and drops them from `displayedFiles`. The rest of the list stays put.
    func test_deleteSelected_removesDeletedFilesFromResults() async {
        let a = makeFile(name: "a", size: 100, accessDaysAgo: 1, category: .largeFile)
        let b = makeFile(name: "b", size: 200, accessDaysAgo: 1, category: .largeFile)
        let c = makeFile(name: "c", size: 300, accessDaysAgo: 1, category: .largeFile)
        let recorded = ActorBox<[URL]>([])
        let vm = makeViewModel(
            scanner: { [a, b, c] },
            deleter: { urls in
                await recorded.set(urls)
                return urls.reduce(into: Set<URL>()) { $0.insert($1) }
            }
        )

        await vm.scan()
        vm.toggleSelection(a)
        vm.toggleSelection(c)

        await vm.deleteSelected()

        let received = await recorded.value
        XCTAssertEqual(Set(received), [a.url, c.url])
        XCTAssertEqual(vm.displayedFiles.map(\.url), [b.url],
                       "Only the surviving file should remain")
        XCTAssertTrue(vm.selectedURLs.isEmpty,
                      "Selection set must clear once the deleted files are gone")
    }

    /// Deleting the last item must transition to `.empty` so the view drops
    /// the table for the empty-state copy. Staying on `.results([])` would
    /// leave the user looking at an empty table with a disabled Delete
    /// button — no signal that the operation succeeded.
    func test_deleteSelected_emptyResultsTransitionsToEmpty() async {
        let only = makeFile(name: "solo", size: 100, accessDaysAgo: 1, category: .largeFile)
        let vm = makeViewModel(
            scanner: { [only] },
            deleter: { Set($0) }
        )
        await vm.scan()
        vm.toggleSelection(only)

        await vm.deleteSelected()

        XCTAssertEqual(vm.phase, .empty)
    }

    /// A deleter that succeeds for only some files must leave the failures in
    /// the displayed list — we report what actually happened, not what was
    /// requested. The deleter contract returns the set of URLs successfully
    /// removed; the VM trusts that.
    func test_deleteSelected_keepsFilesThatWereNotDeleted() async {
        let a = makeFile(name: "a", size: 100, accessDaysAgo: 1, category: .largeFile)
        let b = makeFile(name: "b", size: 200, accessDaysAgo: 1, category: .largeFile)
        let vm = makeViewModel(
            scanner: { [a, b] },
            deleter: { _ in [a.url] }
        )
        await vm.scan()
        vm.toggleSelection(a)
        vm.toggleSelection(b)

        await vm.deleteSelected()

        XCTAssertEqual(vm.displayedFiles.map(\.url), [b.url])
    }

    // MARK: - Helpers

    private func makeViewModel(
        scanner: @escaping () async throws -> [ScannedFile] = { [] },
        deleter: @escaping ([URL]) async -> Set<URL> = { Set($0) }
    ) -> LargeOldFilesViewModel {
        LargeOldFilesViewModel(scanner: scanner, deleter: deleter)
    }

    private func makeFile(
        name: String,
        size: Int64,
        accessDaysAgo: Double,
        category: ScanCategory
    ) -> ScannedFile {
        let date = Date().addingTimeInterval(-accessDaysAgo * 86_400)
        return ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-vm/\(name)"),
            size: size,
            lastAccessDate: date,
            lastModifiedDate: date,
            category: category
        )
    }
}

/// Same actor-box pattern used in `SystemJunkViewModelTests` — lets the
/// `@Sendable` deleter closure record the inputs it received without tripping
/// strict-concurrency warnings.
private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}
