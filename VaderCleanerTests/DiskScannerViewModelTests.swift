// DiskScannerViewModelTests.swift
// Verifies DiskScannerViewModel's state machine (.idle → .scanning → .ready / .error) and that injected progress callbacks update scanProgress on the main actor.

import XCTest
import Combine
@testable import VaderCleaner

/// Drives `DiskScannerViewModel` against an injected scanner closure so the
/// transitions can be exercised without touching the real filesystem. The
/// closure also lets us drive the progress callback at controlled points
/// to lock the threading contract on `scanProgress`.
@MainActor
final class DiskScannerViewModelTests: XCTestCase {

    // MARK: - Happy path

    /// A successful scan must transition `.idle → .scanning → .ready(node)`
    /// and surface the produced root via `phase`. `scanProgress` lands at
    /// 1.0 once the scan is finished.
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
        XCTAssertEqual(vm.scanProgress, 1.0)
    }

    // MARK: - Failure path

    /// An error thrown by the injected scanner must surface as `.error`
    /// carrying the localized description so the view can render it. The
    /// `scanProgress` value is reset back to 0 — leaving the bar
    /// half-full would lie about state.
    func test_startScan_transitionsToErrorOnThrow() async {
        struct ScanFailure: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let vm = DiskScannerViewModel(scanner: { _, _ in
            throw ScanFailure()
        })

        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 1)

        XCTAssertEqual(vm.phase, .error("boom"))
        XCTAssertEqual(vm.scanProgress, 0.0)
    }

    // MARK: - Progress

    /// The injected progress callback must drive `scanProgress` toward 1.0
    /// as the count climbs. Locks the divisor (estimated file count), the
    /// clamp at 1.0 (counts above the estimate must not push past full),
    /// and the throttle bypass for the terminal value.
    ///
    /// `await Task.yield()` between progress calls is deliberate: the VM
    /// hops every published update through `Task { @MainActor … }` so
    /// the writes serialize with view reads. In production the scanner
    /// runs off-actor and naturally yields between tree directories; the
    /// test mirrors that pacing so each queued main-actor write applies
    /// while the phase is still `.scanning`. Without yields the writes
    /// would all queue, then bail on the post-scan phase guard, and the
    /// test would only see the explicit final 1.0.
    func test_startScan_updatesScanProgressFromCallback() async {
        let synthetic = DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            size: 0,
            isDirectory: true,
            children: []
        )
        let vm = DiskScannerViewModel(scanner: { _, progress in
            progress(10)   // 10% of 100
            await Task.yield()
            progress(50)   // 50% of 100
            await Task.yield()
            progress(150)  // > 100 → clamped to 1.0
            await Task.yield()
            return synthetic
        })

        // Snapshot scanProgress every time the observed value changes.
        let observed = await recordTransitions(of: \.scanProgress, on: vm) {
            await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 100)
        }

        // Progress callback must have produced at least one value strictly
        // between 0 and 1 during the scan, never exceeding 1.0.
        XCTAssertTrue(observed.contains { $0 > 0 && $0 < 1 },
                      "scanProgress should report intermediate values during a scan")
        XCTAssertTrue(observed.allSatisfy { $0 <= 1.0 },
                      "scanProgress must never exceed 1.0")
        // Final value (post-scan) is 1.0.
        XCTAssertEqual(vm.scanProgress, 1.0)
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
        XCTAssertEqual(vm.scanProgress, 0.0)
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
        XCTAssertEqual(vm.scanProgress, 0.0)
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
