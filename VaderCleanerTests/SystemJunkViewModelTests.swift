// SystemJunkViewModelTests.swift
// Tests the SystemJunkViewModel state machine, selection logic, and clean dispatch — driving each transition (idle → scanning → preview → cleaning → complete) through injected fake scanner and deleter closures so no real filesystem or XPC helper is touched.

import XCTest
import Combine
@testable import VaderCleaner

@MainActor
final class SystemJunkViewModelTests: XCTestCase {

    // MARK: - Initial state

    /// The view-model must arrive in `.idle` so the System Junk view renders
    /// its "Scan" CTA on first appearance, not a momentary preview/cleaning
    /// flash from a stale cached state.
    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.selectedURLs.isEmpty)
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Scan transitions

    /// `scan()` must advance through `.scanning` and land on `.preview` once
    /// the injected scanner closure resolves. We assert the transient
    /// `.scanning` value with a continuation-gated scanner — once the gate
    /// suspends the scan, the test reads `phase` directly. Without that
    /// gate the test would silently pass even if the VM jumped straight
    /// from `.idle` to `.preview`. The post-gate assertion confirms the
    /// terminal phase is `.preview(result)`. Same pattern
    /// `ScanCoordinatingConformanceTests` uses to pin `.scanning`.
    func test_scan_transitionsIdleToScanningToPreview() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.userLogs,  [makeFile(name: "b", size: 200, category: .userLogs)])
        )
        let gate = ScanPhaseGate()
        let vm = makeViewModel(
            scanner: {
                await gate.wait()
                return result
            },
            deleter: noopDeleter
        )

        XCTAssertEqual(vm.phase, .idle, "Expected initial phase to be .idle")

        let task = Task { await vm.scan() }
        await yieldUntil({ vm.phase == .scanning }, "scan() advanced to .scanning")
        XCTAssertEqual(vm.phase, .scanning)

        await gate.open()
        await task.value
        XCTAssertEqual(vm.phase, .preview(result))
    }

    /// Single-shot continuation gate so the test can freeze `scan()` mid-flight
    /// to observe `.scanning`, then resume to observe `.preview`. Mirrors
    /// `ScanCoordinatingConformanceTests.ScanGate`; lives here so this file
    /// stays self-contained.
    @MainActor
    private final class ScanPhaseGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func yieldUntil(
        _ predicate: () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for: \(message)", file: file, line: line)
    }

    /// Safe-by-default: a fresh scan pre-checks every file in a regenerable /
    /// already-discarded category (caches, logs, Trash) but leaves user-data
    /// categories (mail attachments, iOS backups) unchecked — the same rule
    /// Smart Scan applies, so the two surfaces stay consistent.
    func test_scan_selectsSafeCategoriesByDefault() async {
        let cache = makeFile(name: "a", size: 100, category: .userCache)
        let log = makeFile(name: "b", size: 200, category: .systemLogs)
        let trash = makeFile(name: "c", size: 300, category: .trash)
        let mail = makeFile(name: "d", size: 400, category: .mailAttachments)
        let backup = makeFile(name: "e", size: 500, category: .iosBackups)
        let result = makeResult(
            (.userCache, [cache]),
            (.systemLogs, [log]),
            (.trash, [trash]),
            (.mailAttachments, [mail]),
            (.iosBackups, [backup])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)

        await vm.scan()

        XCTAssertEqual(vm.selectedURLs, [cache.url, log.url, trash.url],
                       "Only safe-category files are pre-checked")
        XCTAssertFalse(vm.selectedURLs.contains(mail.url), "Mail attachments stay opt-in")
        XCTAssertFalse(vm.selectedURLs.contains(backup.url), "iOS backups stay opt-in")
        XCTAssertEqual(vm.totalSelectedSize, 600, "Selected total covers only the safe files")
    }

    /// A scanner that throws must surface a `.failed` phase rather than leave
    /// the view-model stuck in `.scanning` — otherwise the spinner would never
    /// resolve and the user has no way back.
    func test_scan_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(
            scanner: { throw BoomError() },
            deleter: noopDeleter
        )

        await vm.scan()

        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Selection

    /// Toggling a file off must drop both its URL and its bytes from
    /// `totalSelectedSize`. Toggling it back on must restore the total — the
    /// selection state is purely additive, with no side-effects on the
    /// underlying scan result.
    func test_toggleSelection_updatesSelectedURLsAndTotalSelectedSize() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 250, category: .userLogs)
        let result = makeResult(
            (.userCache, [a]),
            (.userLogs,  [b])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        clearSelection(vm, a, b)  // start from an empty baseline
        XCTAssertEqual(vm.totalSelectedSize, 0)

        vm.toggleSelection(a)
        XCTAssertTrue(vm.selectedURLs.contains(a.url))
        XCTAssertEqual(vm.totalSelectedSize, 100)

        vm.toggleSelection(a)
        XCTAssertFalse(vm.selectedURLs.contains(a.url))
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Clean

    /// `clean()` must hand the deleter only the files that are currently
    /// selected. A deselected file must not be passed through — we cannot rely
    /// on the deleter to filter, the view-model owns the contract.
    func test_clean_invokesDeleterOnlyForSelectedFiles() async {
        let userFile = makeFile(name: "a", size: 100, category: .userCache)
        let logFile  = makeFile(name: "b", size: 250, category: .userLogs)
        let result = makeResult(
            (.userCache, [userFile]),
            (.userLogs,  [logFile])
        )
        let recorded = ActorBox<[ScannedFile]>([])
        let vm = makeViewModel(
            scanner: { result },
            deleter: { files in
                await recorded.set(files)
                return files.reduce(Int64(0)) { $0 + $1.size }
            }
        )

        await vm.scan()
        // Both safe-category files are selected by default; deselect the log
        // file so only the user-cache file remains for the deleter.
        vm.toggleSelection(logFile)
        await vm.clean()

        let received = await recorded.value
        XCTAssertEqual(received, [userFile], "Deleter must receive only selected files")
    }

    /// After a successful clean, the phase becomes `.complete(bytesFreed)` so
    /// the view can render the success summary and offer "Scan Again". Bytes
    /// freed comes from the deleter so partial-failure cases (helper deletes
    /// 9 of 10 files) report accurate values rather than the full selection.
    func test_clean_transitionsToCompleteWithBytesFreed() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 1_024, category: .userCache)])
        )
        let file = makeFile(name: "a", size: 1_024, category: .userCache)
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in 1_024 }
        )

        await vm.scan()
        // The cache file is selected by default (safe category); clean it.
        await vm.clean()

        XCTAssertEqual(vm.phase, .complete(bytesFreed: 1_024))
    }

    /// A throwing deleter must surface `.failed` rather than leaving the user
    /// stuck on the cleaning spinner. We don't claim "X bytes freed" if the
    /// underlying delete blew up — better to show an error and let the user
    /// retry.
    func test_clean_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let file = makeFile(name: "a", size: 100, category: .userCache)
        let result = makeResult((.userCache, [file]))
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in throw BoomError() }
        )

        await vm.scan()
        // The cache file is selected by default (safe category); clean reaches the deleter.
        await vm.clean()

        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    /// `clean()` is a no-op when nothing is selected — the View disables the
    /// button in this state, but the VM contract must hold even if a hot-key
    /// path or future caller bypasses the disabled state.
    func test_clean_withNoSelectionDoesNotInvokeDeleter() async {
        let file = makeFile(name: "a", size: 100, category: .userCache)
        let result = makeResult((.userCache, [file]))
        let invoked = ActorBox(false)
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in
                await invoked.set(true)
                return 0
            }
        )

        await vm.scan()
        // Deselect the safe-by-default file so nothing is selected.
        clearSelection(vm, file)
        await vm.clean()

        let didInvoke = await invoked.value
        XCTAssertFalse(didInvoke, "Deleter must not be called when no file is selected")
    }

    /// `selectOnly(categories:)` backs a card's Review: it must replace the
    /// selection with exactly that group's files, so the selected total equals
    /// the card's displayed size.
    func test_selectOnly_replacesSelectionWithGroupFiles() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 200, category: .systemCache)
        let trash  = makeFile(name: "t", size: 400, category: .trash)
        let result = makeResult(
            (.userCache, [cacheA]),
            (.systemCache, [cacheB]),
            (.trash, [trash])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        vm.toggleSelection(trash) // a pre-existing selection that must be cleared

        await vm.selectOnly(categories: [.userCache, .systemCache])

        XCTAssertEqual(vm.selectedURLs, [cacheA.url, cacheB.url])
        XCTAssertEqual(vm.totalSelectedSize, 300)
    }

    // MARK: - Per-category selected bytes (Cleanup Manager badge)

    /// Toggling a file must move its bytes into (and out of) its own category's
    /// running total, leaving sibling categories untouched — so the manager's
    /// per-category badge reads O(1) instead of re-scanning every file.
    func test_selectedBytesPerCategory_tracksTogglesPerCategory() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 30, category: .userCache)
        let log = makeFile(name: "c", size: 250, category: .userLogs)
        let result = makeResult((.userCache, [cacheA, cacheB]), (.userLogs, [log]))
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        clearSelection(vm, cacheA, cacheB, log)  // start from an empty baseline

        vm.toggleSelection(cacheA)
        vm.toggleSelection(log)
        XCTAssertEqual(vm.selectedBytes(in: .userCache), 100)
        XCTAssertEqual(vm.selectedBytes(in: .userLogs), 250)
        XCTAssertEqual(vm.selectedBytes(in: .trash), 0, "Untouched categories read zero")

        vm.toggleSelection(cacheB)
        XCTAssertEqual(vm.selectedBytes(in: .userCache), 130)

        vm.toggleSelection(cacheA)
        XCTAssertEqual(vm.selectedBytes(in: .userCache), 30, "Deselecting subtracts only that file")
        XCTAssertEqual(vm.selectedBytes(in: .userLogs), 250, "A sibling category is unaffected")
    }

    /// The per-category totals must equal the grand total at all times.
    func test_selectedBytesPerCategory_sumsToTotalSelectedSize() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let log = makeFile(name: "c", size: 250, category: .userLogs)
        let result = makeResult((.userCache, [cacheA]), (.userLogs, [log]))
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        clearSelection(vm, cacheA, log)  // start from an empty baseline

        vm.toggleSelection(cacheA)
        vm.toggleSelection(log)

        XCTAssertEqual(
            vm.selectedBytes(in: .userCache) + vm.selectedBytes(in: .userLogs),
            vm.totalSelectedSize
        )
    }

    /// `selectOnly` rebuilds the per-category totals to exactly the chosen
    /// group's files, zeroing categories that fall outside the group.
    func test_selectedBytesPerCategory_afterSelectOnly() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 200, category: .systemCache)
        let trash = makeFile(name: "t", size: 400, category: .trash)
        let result = makeResult((.userCache, [cacheA]), (.systemCache, [cacheB]), (.trash, [trash]))
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        vm.toggleSelection(trash) // a pre-existing selection outside the group

        await vm.selectOnly(categories: [.userCache, .systemCache])

        XCTAssertEqual(vm.selectedBytes(in: .userCache), 100)
        XCTAssertEqual(vm.selectedBytes(in: .systemCache), 200)
        XCTAssertEqual(vm.selectedBytes(in: .trash), 0, "selectOnly clears categories outside the group")
    }

    /// A fresh scan and `scanAgain()` must drop the per-category totals so the
    /// badge never carries a previous run's selection forward.
    func test_selectedBytesPerCategory_clearedOnScanAndScanAgain() async {
        // A risky (opt-in) category so a fresh scan leaves it unselected, keeping
        // the focus on scanAgain() clearing the running total.
        let file = makeFile(name: "a", size: 100, category: .mailAttachments)
        let result = makeResult((.mailAttachments, [file]))
        let vm = makeViewModel(scanner: { result }, deleter: { _ in 100 })

        await vm.scan()
        XCTAssertEqual(vm.selectedBytes(in: .mailAttachments), 0, "A risky category isn't pre-checked")

        vm.toggleSelection(file)
        XCTAssertEqual(vm.selectedBytes(in: .mailAttachments), 100)

        vm.scanAgain()
        XCTAssertEqual(vm.selectedBytes(in: .mailAttachments), 0)
    }

    // MARK: - Per-category selected count (bulk-select menu)

    /// The per-category selected *count* is maintained incrementally on every
    /// toggle so the Cleanup Manager's "Select: None/All/Some" menu reads O(1)
    /// instead of re-scanning every file in the category on each render.
    func test_selectedCountPerCategory_tracksTogglesPerCategory() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 30, category: .userCache)
        let log = makeFile(name: "c", size: 250, category: .userLogs)
        let result = makeResult((.userCache, [cacheA, cacheB]), (.userLogs, [log]))
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        clearSelection(vm, cacheA, cacheB, log)  // start from an empty baseline

        vm.toggleSelection(cacheA)
        vm.toggleSelection(log)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 1)
        XCTAssertEqual(vm.selectedCount(in: .userLogs), 1)
        XCTAssertEqual(vm.selectedCount(in: .trash), 0, "Untouched categories read zero")

        vm.toggleSelection(cacheB)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 2)

        vm.toggleSelection(cacheA)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 1, "Deselecting subtracts only that file")
        XCTAssertEqual(vm.selectedCount(in: .userLogs), 1, "A sibling category is unaffected")
    }

    /// `selectOnly` rebuilds the per-category counts to exactly the chosen
    /// group's files, zeroing categories that fall outside the group.
    func test_selectedCountPerCategory_afterSelectOnly() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 200, category: .systemCache)
        let trash = makeFile(name: "t", size: 400, category: .trash)
        let result = makeResult((.userCache, [cacheA]), (.systemCache, [cacheB]), (.trash, [trash]))
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        vm.toggleSelection(trash) // a pre-existing selection outside the group

        await vm.selectOnly(categories: [.userCache, .systemCache])

        XCTAssertEqual(vm.selectedCount(in: .userCache), 1)
        XCTAssertEqual(vm.selectedCount(in: .systemCache), 1)
        XCTAssertEqual(vm.selectedCount(in: .trash), 0, "selectOnly clears categories outside the group")
    }

    /// A fresh scan and `scanAgain()` must drop the per-category counts so the
    /// menu never carries a previous run's selection forward.
    func test_selectedCountPerCategory_clearedOnScanAndScanAgain() async {
        // A risky (opt-in) category so a fresh scan leaves it unselected, keeping
        // the focus on scanAgain() clearing the running count.
        let file = makeFile(name: "a", size: 100, category: .mailAttachments)
        let result = makeResult((.mailAttachments, [file]))
        let vm = makeViewModel(scanner: { result }, deleter: { _ in 100 })

        await vm.scan()
        XCTAssertEqual(vm.selectedCount(in: .mailAttachments), 0, "A risky category isn't pre-checked")

        vm.toggleSelection(file)
        XCTAssertEqual(vm.selectedCount(in: .mailAttachments), 1)

        vm.scanAgain()
        XCTAssertEqual(vm.selectedCount(in: .mailAttachments), 0)
    }

    // MARK: - Bulk selection (folder-row / category toggle)

    /// `setSelection(_:selected:)` selects a whole group in one pass, updating
    /// the URL set and every running total. This backs the Cleanup Manager's
    /// folder-row and category toggles, which cover thousands of files — doing
    /// the work per file (and firing observation per file) is what froze the UI.
    func test_setSelection_selectsGroupAndUpdatesTotals() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 30, category: .userCache)
        let c = makeFile(name: "c", size: 250, category: .userLogs)
        let vm = makeViewModel(scanner: { self.makeResult((.userCache, [a, b]), (.userLogs, [c])) }, deleter: noopDeleter)
        await vm.scan()

        vm.setSelection([a, b, c], selected: true)

        XCTAssertEqual(vm.selectedURLs, [a.url, b.url, c.url])
        XCTAssertEqual(vm.totalSelectedSize, 380)
        XCTAssertEqual(vm.selectedBytes(in: .userCache), 130)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 2)
        XCTAssertEqual(vm.selectedBytes(in: .userLogs), 250)
        XCTAssertEqual(vm.selectedCount(in: .userLogs), 1)
    }

    /// Deselecting a group removes exactly those files and no others.
    func test_setSelection_deselectsOnlyGivenFiles() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 30, category: .userCache)
        let vm = makeViewModel(scanner: { self.makeResult((.userCache, [a, b])) }, deleter: noopDeleter)
        await vm.scan()
        vm.setSelection([a, b], selected: true)

        vm.setSelection([a], selected: false)

        XCTAssertEqual(vm.selectedURLs, [b.url])
        XCTAssertEqual(vm.totalSelectedSize, 30)
        XCTAssertEqual(vm.selectedBytes(in: .userCache), 30)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 1)
    }

    /// Re-selecting already-selected files (or clearing unselected ones) must
    /// not double-count the totals — the bulk pass is idempotent per file.
    func test_setSelection_isIdempotentPerFile() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let vm = makeViewModel(scanner: { self.makeResult((.userCache, [a])) }, deleter: noopDeleter)
        await vm.scan()

        vm.setSelection([a], selected: true)
        vm.setSelection([a], selected: true) // repeat — must be a no-op

        XCTAssertEqual(vm.selectedURLs, [a.url])
        XCTAssertEqual(vm.totalSelectedSize, 100)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 1)
    }

    /// `toggleSelection(_ files:)` selects the group when it isn't already fully
    /// selected, and clears it when every file is selected — the folder-row
    /// checkbox's all-or-nothing behavior.
    func test_toggleSelectionGroup_selectsThenClears() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 30, category: .userCache)
        let vm = makeViewModel(scanner: { self.makeResult((.userCache, [a, b])) }, deleter: noopDeleter)
        await vm.scan()
        clearSelection(vm, a, b)  // start from an empty baseline

        vm.toggleSelection([a, b]) // nothing selected → select all
        XCTAssertTrue(vm.areAllSelected([a, b]))
        XCTAssertEqual(vm.selectedCount(in: .userCache), 2)

        vm.toggleSelection([a, b]) // all selected → clear all
        XCTAssertTrue(vm.selectedURLs.isEmpty)
        XCTAssertEqual(vm.selectedCount(in: .userCache), 0)
    }

    /// A partially-selected group toggles to fully selected (not cleared), so a
    /// folder with one checked child fills in rather than emptying.
    func test_toggleSelectionGroup_partialSelectsRest() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 30, category: .userCache)
        let vm = makeViewModel(scanner: { self.makeResult((.userCache, [a, b])) }, deleter: noopDeleter)
        await vm.scan()
        clearSelection(vm, a, b)  // start from an empty baseline
        vm.setSelection([a], selected: true) // only one of two selected

        vm.toggleSelection([a, b])

        XCTAssertTrue(vm.areAllSelected([a, b]), "A partial group toggles to fully selected")
    }

    // MARK: - Clean by category (dashboard card "Clean")

    /// `clean(categories:)` backs a dashboard card's Clean button: it must
    /// delete every file in those categories regardless of the per-file
    /// selection state — even files the user toggled off in a review.
    func test_cleanCategories_deletesAllFilesInGroupIgnoringSelection() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 200, category: .systemCache)
        let trash  = makeFile(name: "t", size: 400, category: .trash)
        let result = makeResult(
            (.userCache, [cacheA]),
            (.systemCache, [cacheB]),
            (.trash, [trash])
        )
        let recorded = ActorBox<[ScannedFile]>([])
        let vm = makeViewModel(
            scanner: { result },
            deleter: { files in
                await recorded.set(files)
                return files.reduce(Int64(0)) { $0 + $1.size }
            }
        )

        await vm.scan()
        vm.toggleSelection(cacheA) // deselect one of the group's files
        await vm.clean(categories: [.userCache, .systemCache])

        let received = await recorded.value
        XCTAssertEqual(
            Set(received), [cacheA, cacheB],
            "clean(categories:) must delete the whole group, not just the selected files"
        )
        XCTAssertEqual(vm.phase, .complete(bytesFreed: 300))
    }

    /// Cleaning a group with no scanned files must not call the deleter or leave
    /// the preview — there is nothing to do.
    func test_cleanCategories_withNoMatchingFiles_isNoOp() async {
        let trash = makeFile(name: "t", size: 400, category: .trash)
        let result = makeResult((.trash, [trash]))
        let invoked = ActorBox(false)
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in
                await invoked.set(true)
                return 0
            }
        )

        await vm.scan()
        await vm.clean(categories: [.xcodeJunk])

        let didInvoke = await invoked.value
        XCTAssertFalse(didInvoke, "Deleter must not run for an empty group")
        XCTAssertEqual(vm.phase, .preview(result), "Phase must stay on the dashboard")
    }

    /// A throwing deleter on a card Clean must surface `.failed`, same as the
    /// selection-based clean.
    func test_cleanCategories_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let result = makeResult((.trash, [makeFile(name: "t", size: 1, category: .trash)]))
        let vm = makeViewModel(scanner: { result }, deleter: { _ in throw BoomError() })

        await vm.scan()
        await vm.clean(categories: [.trash])

        if case .failed = vm.phase {} else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Scan again

    /// `scanAgain()` returns the view-model to `.idle` so the user is back at
    /// the Scan CTA — selection state is dropped because the previous result
    /// is no longer valid.
    func test_scanAgain_returnsToIdle() async {
        let file = makeFile(name: "a", size: 100, category: .userCache)
        let result = makeResult((.userCache, [file]))
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in 100 }
        )
        await vm.scan()
        // The cache file is selected by default (safe category); clean it.
        await vm.clean()
        XCTAssertEqual(vm.phase, .complete(bytesFreed: 100))

        vm.scanAgain()

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.selectedURLs.isEmpty)
    }

    // MARK: - Scan progress count

    /// The scanner's progress callback must drive `scannedItemCount` so the
    /// scanning screen can show the walk advancing.
    func test_scan_reportsScannedItemCountFromProgress() async {
        let vm = SystemJunkViewModel(
            scanner: { progress in
                progress(64)
                await Task.yield()
                progress(900)
                await Task.yield()
                return ScanResult(items: [])
            },
            deleter: { _ in 0 }
        )

        await vm.scan()
        await waitUntil { vm.scannedItemCount == 900 }

        XCTAssertEqual(vm.scannedItemCount, 900)
    }

    /// Each scan must restart the counter from zero rather than carry the
    /// previous run's total forward.
    func test_scan_restartsScannedItemCountEachScan() async {
        let vm = SystemJunkViewModel(
            scanner: { progress in
                progress(900)
                await Task.yield()
                return ScanResult(items: [])
            },
            deleter: { _ in 0 }
        )

        await vm.scan()
        await waitUntil { vm.scannedItemCount == 900 }

        let observed = await recordTransitions(of: \.scannedItemCount, on: vm) {
            await vm.scan()
            await waitUntil { vm.scannedItemCount == 900 }
        }

        XCTAssertTrue(
            observed.contains(0),
            "A new scan must reset the counter to zero before counting up again, got \(observed)"
        )
    }

    // MARK: - Seed (from Smart Scan)

    func test_seed_fromIdle_landsInPreviewWithSafeCategoriesSelected() async {
        let vm = makeViewModel()
        let cache = makeFile(name: "a", size: 100, category: .userCache)
        let mail = makeFile(name: "b", size: 400, category: .mailAttachments)
        let result = makeResult((.userCache, [cache]), (.mailAttachments, [mail]))

        await vm.seed(with: result)

        XCTAssertEqual(vm.phase, .preview(result))
        XCTAssertEqual(vm.selectedURLs, [cache.url],
                       "A seeded result lands on the same safe-by-default selection as scan()")
        XCTAssertEqual(vm.totalSelectedSize, 100)
    }

    func test_seed_whenNotIdle_isIgnored() async {
        let vm = makeViewModel(scanner: { ScanResult(items: []) })
        await vm.scan() // leaves .idle for .preview(empty)

        let file = makeFile(name: "a", size: 100, category: .userCache)
        await vm.seed(with: makeResult((.userCache, [file])))

        // The seed is dropped because the section already left idle.
        XCTAssertEqual(vm.phase, .preview(ScanResult(items: [])))
    }

    // MARK: - Helpers

    // MARK: - Cleanup Manager store ownership

    /// A completed scan warms the view-model-owned Cleanup Manager store so
    /// opening Review serves the fresh results without a per-open rebuild —
    /// and without the view owning (and tearing down on every section switch)
    /// the potentially huge cache.
    func test_scan_warmsManagerStore() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        let vm = makeViewModel(scanner: { ScanResult(items: [junkFile]) })

        await vm.scan()

        XCTAssertFalse(
            vm.managerStore.items(forCategoryID: ScanCategory.userCache.rawValue).isEmpty,
            "The store must serve the completed scan's junk files"
        )
    }

    /// The Smart Scan seed path warms the store the same way a direct scan
    /// does — the section's Review must work without this view ever scanning.
    func test_seed_warmsManagerStore() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        let vm = makeViewModel()

        await vm.seed(with: ScanResult(items: [junkFile]))

        XCTAssertFalse(
            vm.managerStore.items(forCategoryID: ScanCategory.userCache.rawValue).isEmpty,
            "Seeding must warm the store like a scan does"
        )
    }

    /// Start Over releases the store's data alongside the rest of the scan
    /// state, so a reset session doesn't keep a large scan's index alive.
    func test_scanAgain_unloadsManagerStore() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        let vm = makeViewModel(scanner: { ScanResult(items: [junkFile]) })
        await vm.scan()

        vm.scanAgain()

        XCTAssertTrue(vm.managerStore.items(forCategoryID: ScanCategory.userCache.rawValue).isEmpty)
    }

    private func makeViewModel(
        scanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        deleter: @escaping ([ScannedFile]) async throws -> Int64 = { _ in 0 }
    ) -> SystemJunkViewModel {
        // Adapt the progress-free test closures to the production scanner
        // signature; the count test constructs the VM directly to drive the
        // progress callback.
        SystemJunkViewModel(scanner: { _ in try await scanner() }, deleter: deleter)
    }

    private func makeResult(_ groups: (ScanCategory, [ScannedFile])...) -> ScanResult {
        let items = groups.flatMap { $0.1 }
        return ScanResult(items: items)
    }

    private func makeFile(name: String, size: Int64, category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/sjv-tests/\(category.rawValue)/\(name)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    /// Default no-op deleter for tests that don't exercise the clean path.
    private let noopDeleter: ([ScannedFile]) async throws -> Int64 = { _ in 0 }

    /// Deselects `files` so a selection-mechanics test starts from an empty
    /// baseline, independent of the safe-by-default seed a scan now applies.
    private func clearSelection(_ vm: SystemJunkViewModel, _ files: ScannedFile...) {
        vm.setSelection(files, selected: false)
    }
}

/// Small actor wrapper that lets test deleter closures record values without
/// data-race warnings under Swift's strict concurrency checks. The deleter
/// closure is `@Sendable`, so it cannot capture a `@MainActor` test fixture's
/// stored properties directly — funnelling values through an actor is the
/// simplest race-free alternative.
private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}
