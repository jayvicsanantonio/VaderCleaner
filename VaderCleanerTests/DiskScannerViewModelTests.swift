// DiskScannerViewModelTests.swift
// Verifies DiskScannerViewModel's state machine (.idle → .scanning → .ready / .error) and that injected progress callbacks update scannedItemCount on the main actor.

import XCTest
import Combine
@testable import VaderCleaner

/// Drives `DiskScannerViewModel` against an injected scanner closure so the
/// transitions can be exercised without touching the real filesystem. The
/// closure also lets us drive the progress callback at controlled points
/// to lock the threading contract on `scannedItemCount`.
@MainActor
final class DiskScannerViewModelTests: XCTestCase {

    // MARK: - Happy path

    /// A successful scan must transition `.idle → .scanning → .ready(node)`
    /// and surface the produced root via `phase`.
    func test_startScan_transitionsToReadyOnSuccess() async {
        let synthetic = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 100,
            isDirectory: true,
            children: []
        )
        let vm = DiskScannerViewModel(scanner: { _, progress in
            // Drive progress mid-scan so the test also pins the in-flight
            // value path through the VM.
            progress(50)
            return synthetic
        })

        XCTAssertEqual(vm.phase, .idle)
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 100)

        XCTAssertEqual(vm.phase, .ready(synthetic))
    }

    // MARK: - Failure path

    /// An error thrown by the injected scanner must surface as `.error`
    /// carrying the localized description so the view can render it. The
    /// walked count is reset back to 0 — a leftover count would read as
    /// progress against a scan that isn't running.
    func test_startScan_transitionsToErrorOnThrow() async {
        struct ScanFailure: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let vm = DiskScannerViewModel(scanner: { _, _ in
            throw ScanFailure()
        })

        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        XCTAssertEqual(vm.phase, .error("boom"))
        XCTAssertEqual(vm.scannedItemCount, 0)
    }

    // MARK: - Progress

    /// The progress callback must drive `scannedItemCount` upward as the
    /// walk advances, ending on the last reported count.
    ///
    /// `await Task.yield()` between progress calls is deliberate: the VM
    /// hops every published update through `Task { @MainActor … }` so
    /// the writes serialize with view reads. In production the scanner
    /// runs off-actor and naturally yields between tree directories; the
    /// test mirrors that pacing so each queued main-actor write applies
    /// while the phase is still `.scanning`. Without yields the writes
    /// would all queue, then bail on the post-scan phase guard, and the
    /// test would only see the final value.
    func test_startScan_updatesScannedItemCountFromCallback() async {
        let synthetic = DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            size: 0,
            isDirectory: true,
            children: []
        )
        let vm = DiskScannerViewModel(scanner: { _, progress in
            progress(10)
            await Task.yield()
            progress(50)
            await Task.yield()
            return synthetic
        })

        // Snapshot scannedItemCount every time the observed value changes.
        let observed = await recordTransitions(of: \.scannedItemCount, on: vm) {
            await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 100)
        }

        // The count must only ever climb — a backwards tick would read as the
        // scan losing ground.
        XCTAssertEqual(observed, observed.sorted(),
                       "scannedItemCount must be monotonically non-decreasing")
        // Ends on the last count the scanner reported.
        XCTAssertEqual(vm.scannedItemCount, 50)
    }

    /// Regression guard for the pinned-progress bug: a real volume holds far
    /// more files than the default estimate. The walked count must keep
    /// climbing past the estimate rather than being capped or latched there —
    /// the old fixed-divisor bar pinned at 100% once the count hit the
    /// estimate, which read as "done" while a minute of scanning was still
    /// ahead.
    func test_startScan_countClimbsPastEstimate() async {
        let synthetic = DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            size: 0,
            isDirectory: true,
            children: []
        )
        let vm = DiskScannerViewModel(scanner: { _, progress in
            progress(50)    // within the 100-file estimate
            await Task.yield()
            progress(500)   // well past the estimate — must not be capped
            await Task.yield()
            return synthetic
        })

        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 100)

        XCTAssertEqual(vm.scannedItemCount, 500,
                       "the walked count must continue past the estimate, not cap at it")
    }

    // MARK: - Cancellation

    /// A `CancellationError` is a clean dismissal (a fresh scan replaced
    /// this one, or the user navigated away), not a failure. The VM must
    /// route it back to `.idle` rather than `.error("The operation
    /// couldn't be completed…")`, which the upcoming UI would render as
    /// a scan failure banner.
    func test_startScan_treatsCancellationErrorAsCleanDismissal() async {
        let vm = DiskScannerViewModel(scanner: { _, _ in
            throw CancellationError()
        })

        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        XCTAssertEqual(vm.phase, .idle, "Cancellation should land back in .idle, not .error")
        XCTAssertEqual(vm.scannedItemCount, 0)
    }

    /// App-scoped Space Lens state can outlive the main window when the
    /// menu bar extra keeps the process running. Explicit cancellation must
    /// stop the scanner instead of waiting for VM teardown.
    func test_cancelScan_cancelsInFlightScanAndReturnsToIdle() async {
        let scanStarted = expectation(description: "scan started")
        let scanCancelled = expectation(description: "scan cancelled")
        let vm = DiskScannerViewModel(scanner: { _, _ in
            scanStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                XCTFail("Expected cancelScan() to cancel the in-flight scanner")
                return DiskNode(
                    url: URL(fileURLWithPath: "/tmp"),
                    name: "tmp",
                    size: 0,
                    isDirectory: true,
                    children: []
                )
            } catch is CancellationError {
                scanCancelled.fulfill()
                throw CancellationError()
            }
        })

        let scanTask = Task {
            await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        }
        await fulfillment(of: [scanStarted], timeout: 1)
        XCTAssertEqual(vm.phase, .scanning)

        vm.cancelScan()

        await fulfillment(of: [scanCancelled], timeout: 1)
        await scanTask.value
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.scannedItemCount, 0)
    }

    // MARK: - Navigation (Prompt 17)

    /// Drilling into a directory child must push it onto the breadcrumb
    /// stack so the treemap re-renders against its children. The order
    /// matters — `navigationPath.last` is the displayed node, so the
    /// freshly-clicked child must end up at the tail.
    func test_drillDown_appendsDirectoryToNavigationPath() async {
        let dirChild = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root/sub"),
            name: "sub",
            size: 50,
            isDirectory: true,
            children: []
        )
        let root = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 50,
            isDirectory: true,
            children: [dirChild]
        )
        let vm = DiskScannerViewModel(scanner: { _, _ in root })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        vm.drillDown(into: dirChild)

        XCTAssertEqual(vm.navigationPath.count, 1)
        XCTAssertTrue(vm.navigationPath.last === dirChild)
    }

    /// Drilling into a deeper descendant (as the sunburst allows when the user
    /// taps a 2nd-or-deeper ring) must record every intermediate folder, not
    /// just the tapped node — otherwise the breadcrumb skips levels and
    /// `navigateUp` jumps back too far.
    func test_drillDown_pushesFullAncestorChainForDescendant() async {
        let grandchild = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root/sub/deep"),
            name: "deep",
            size: 10,
            isDirectory: true,
            children: []
        )
        let child = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root/sub"),
            name: "sub",
            size: 10,
            isDirectory: true,
            children: [grandchild]
        )
        let root = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 10,
            isDirectory: true,
            children: [child]
        )
        let vm = DiskScannerViewModel(scanner: { _, _ in root })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        // Tapping the grandchild directly, as a deep sunburst ring would.
        vm.drillDown(into: grandchild)

        XCTAssertEqual(vm.navigationPath.count, 2)
        XCTAssertTrue(vm.navigationPath.first === child,
                      "The intermediate folder must be recorded, not skipped")
        XCTAssertTrue(vm.navigationPath.last === grandchild)
        XCTAssertTrue(vm.currentNode === grandchild)

        vm.navigateUp()
        XCTAssertTrue(vm.currentNode === child,
                      "Up must step back exactly one real level, to the intermediate folder")
    }

    /// Files cannot be drilled into — the treemap renders `node.children`,
    /// and a file has none, so a misplaced drill-down would land the UI on
    /// an empty rectangle. The VM must reject the call instead of trusting
    /// the view to filter it out.
    func test_drillDown_isNoOpForNonDirectory() async {
        let fileChild = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root/note.txt"),
            name: "note.txt",
            size: 10,
            isDirectory: false,
            children: []
        )
        let root = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 10,
            isDirectory: true,
            children: [fileChild]
        )
        let vm = DiskScannerViewModel(scanner: { _, _ in root })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        vm.drillDown(into: fileChild)

        XCTAssertTrue(vm.navigationPath.isEmpty,
                      "drillDown into a file should be a no-op")
    }

    /// `navigateUp` pops one entry — the back-button affordance behind the
    /// breadcrumb's leftmost crumb.
    func test_navigateUp_popsLastEntryFromNavigationPath() {
        let a = DiskNode(url: URL(fileURLWithPath: "/a"), name: "a",
                         size: 0, isDirectory: true, children: [])
        let b = DiskNode(url: URL(fileURLWithPath: "/a/b"), name: "b",
                         size: 0, isDirectory: true, children: [])
        let vm = DiskScannerViewModel(scanner: { _, _ in
            DiskNode(url: URL(fileURLWithPath: "/"), name: "/",
                     size: 0, isDirectory: true, children: [])
        })
        vm.navigationPath = [a, b]

        vm.navigateUp()

        XCTAssertEqual(vm.navigationPath.count, 1)
        XCTAssertTrue(vm.navigationPath.last === a)
    }

    /// `navigateToRoot` empties the breadcrumb stack in one call so the
    /// root crumb in `SpaceLensView` doesn't have to mutate
    /// `navigationPath` directly. Multi-level no-op safety: a second call
    /// against an already-empty path leaves the path empty.
    func test_navigateToRoot_clearsNavigationPath() {
        let a = DiskNode(url: URL(fileURLWithPath: "/a"), name: "a",
                         size: 0, isDirectory: true, children: [])
        let b = DiskNode(url: URL(fileURLWithPath: "/a/b"), name: "b",
                         size: 0, isDirectory: true, children: [])
        let vm = DiskScannerViewModel(scanner: { _, _ in
            DiskNode(url: URL(fileURLWithPath: "/"), name: "/",
                     size: 0, isDirectory: true, children: [])
        })
        vm.navigationPath = [a, b]

        vm.navigateToRoot()

        XCTAssertTrue(vm.navigationPath.isEmpty)

        // Idempotent — calling again from root must not throw or grow
        // the path back.
        vm.navigateToRoot()
        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    /// `navigateUp` on an empty path is a no-op. Defensive against a
    /// stuck-at-root state where the back button is mistakenly enabled.
    func test_navigateUp_isNoOpWhenPathEmpty() {
        let vm = DiskScannerViewModel(scanner: { _, _ in
            DiskNode(url: URL(fileURLWithPath: "/"), name: "/",
                     size: 0, isDirectory: true, children: [])
        })

        vm.navigateUp()

        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    // MARK: - Back / forward history

    /// `goBack` pops the path and `goForward` re-enters it — the breadcrumb's
    /// `<` / `>` controls. Drilling somewhere new clears the forward trail.
    func test_goBackAndForward_walkHistory() async {
        let child = DiskNode(url: URL(fileURLWithPath: "/tmp/root/dir"), name: "dir",
                             size: 10, isDirectory: true, children: [])
        let root = DiskNode(url: URL(fileURLWithPath: "/tmp/root"), name: "root",
                            size: 10, isDirectory: true, children: [child], itemCount: 1)
        let vm = DiskScannerViewModel(scanner: { _, _ in root })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        vm.drillDown(into: child)
        XCTAssertTrue(vm.currentNode === child)
        XCTAssertFalse(vm.canGoForward)

        vm.goBack()
        XCTAssertTrue(vm.currentNode === root)
        XCTAssertTrue(vm.canGoForward)

        vm.goForward()
        XCTAssertTrue(vm.currentNode === child)

        // Drilling somewhere new wipes the forward history.
        vm.goBack()
        vm.drillDown(into: child)
        XCTAssertFalse(vm.canGoForward)
    }

    // MARK: - Removal

    /// `removeSelected` trashes the selected nodes' URLs and prunes them from
    /// the displayed tree, clearing the selection and the review flag.
    func test_removeSelected_trashesSelectionAndPrunesTree() async {
        let keep = DiskNode(url: URL(fileURLWithPath: "/tmp/root/keep"), name: "keep",
                            size: 100, isDirectory: false, children: [])
        let drop = DiskNode(url: URL(fileURLWithPath: "/tmp/root/drop"), name: "drop",
                            size: 200, isDirectory: false, children: [])
        let root = DiskNode(url: URL(fileURLWithPath: "/tmp/root"), name: "root",
                            size: 300, isDirectory: true, children: [keep, drop], itemCount: 2)

        let trashed = Trashed()
        let vm = DiskScannerViewModel(
            scanner: { _, _ in root },
            trash: { urls in await trashed.record(urls); return Set(urls) },
            volumeUsageProvider: { SpaceLensVolumeUsage(volumeName: "T", usedBytes: 1, totalBytes: 10) }
        )
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        vm.selection.toggle(drop)
        vm.reviewActive = true

        await vm.removeSelected()

        let recorded = await trashed.urls
        XCTAssertEqual(recorded, [drop.url])
        XCTAssertEqual(vm.currentNode?.children.map(\.name), ["keep"])
        XCTAssertTrue(vm.selection.isEmpty)
        XCTAssertFalse(vm.reviewActive)
    }

    /// A node the sink fails to move stays in the tree and selected, so the user
    /// can see it didn't go.
    func test_removeSelected_keepsNodesTheSinkDidNotMove() async {
        let drop = DiskNode(url: URL(fileURLWithPath: "/tmp/root/drop"), name: "drop",
                            size: 200, isDirectory: false, children: [])
        let root = DiskNode(url: URL(fileURLWithPath: "/tmp/root"), name: "root",
                            size: 200, isDirectory: true, children: [drop], itemCount: 1)
        let vm = DiskScannerViewModel(
            scanner: { _, _ in root },
            trash: { _ in [] } // nothing moved (e.g. locked file)
        )
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        vm.selection.toggle(drop)

        await vm.removeSelected()

        XCTAssertEqual(vm.currentNode?.children.map(\.name), ["drop"])
        XCTAssertTrue(vm.selection.isSelected(drop))
    }

    /// Actor that records what the injected trash sink was asked to remove.
    private actor Trashed {
        private(set) var urls: [URL] = []
        func record(_ newURLs: [URL]) { urls.append(contentsOf: newURLs) }
    }

    /// Clicking a breadcrumb crumb truncates the path so the named node
    /// becomes the new tail. Without this, navigating back N levels would
    /// require N separate `navigateUp` calls and the breadcrumb's
    /// "jump to ancestor" affordance would be impossible.
    func test_navigateTo_truncatesNavigationPathAtNode() {
        let a = DiskNode(url: URL(fileURLWithPath: "/a"), name: "a",
                         size: 0, isDirectory: true, children: [])
        let b = DiskNode(url: URL(fileURLWithPath: "/a/b"), name: "b",
                         size: 0, isDirectory: true, children: [])
        let c = DiskNode(url: URL(fileURLWithPath: "/a/b/c"), name: "c",
                         size: 0, isDirectory: true, children: [])
        let vm = DiskScannerViewModel(scanner: { _, _ in
            DiskNode(url: URL(fileURLWithPath: "/"), name: "/",
                     size: 0, isDirectory: true, children: [])
        })
        vm.navigationPath = [a, b, c]

        vm.navigate(to: b)

        XCTAssertEqual(vm.navigationPath.count, 2)
        XCTAssertTrue(vm.navigationPath.last === b)
    }

    /// `navigate(to:)` against a node that isn't on the current path is a
    /// no-op — happens when the tree is rescanned and a stale crumb
    /// reference fires while the new tree hasn't reached the view yet.
    func test_navigateTo_isNoOpWhenNodeNotInPath() {
        let a = DiskNode(url: URL(fileURLWithPath: "/a"), name: "a",
                         size: 0, isDirectory: true, children: [])
        let b = DiskNode(url: URL(fileURLWithPath: "/b"), name: "b",
                         size: 0, isDirectory: true, children: [])
        let vm = DiskScannerViewModel(scanner: { _, _ in
            DiskNode(url: URL(fileURLWithPath: "/"), name: "/",
                     size: 0, isDirectory: true, children: [])
        })
        vm.navigationPath = [a]

        vm.navigate(to: b)

        XCTAssertEqual(vm.navigationPath.count, 1)
        XCTAssertTrue(vm.navigationPath.last === a,
                      "navigate(to:) should leave the path untouched when the node isn't on it")
    }

    /// `currentNode` is the displayed node — root when the breadcrumb is
    /// empty, the deepest crumb otherwise. The treemap binds to its
    /// `children` so this property is the single source of truth for what
    /// the view renders.
    func test_currentNode_isRootWhenPathIsEmpty() async {
        let root = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 100,
            isDirectory: true,
            children: []
        )
        let vm = DiskScannerViewModel(scanner: { _, _ in root })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        XCTAssertTrue(vm.currentNode === root)
    }

    func test_currentNode_isLastEntryWhenPathHasNodes() async {
        let child = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root/sub"),
            name: "sub",
            size: 50,
            isDirectory: true,
            children: []
        )
        let root = DiskNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            size: 50,
            isDirectory: true,
            children: [child]
        )
        let vm = DiskScannerViewModel(scanner: { _, _ in root })
        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)
        vm.drillDown(into: child)

        XCTAssertTrue(vm.currentNode === child)
    }
}
