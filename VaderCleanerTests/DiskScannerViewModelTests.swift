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
        var observed: [Double] = []
        let vm = DiskScannerViewModel(scanner: { _, progress in
            progress(10)   // 10% of 100
            await Task.yield()
            progress(50)   // 50% of 100
            await Task.yield()
            progress(150)  // > 100 → clamped to 1.0
            await Task.yield()
            return synthetic
        })

        // Snapshot scanProgress every time the published value changes.
        let cancellable = vm.$scanProgress.sink { observed.append($0) }
        defer { cancellable.cancel() }

        await vm.startScan(root: URL(fileURLWithPath: "/tmp"), estimatedFileCount: 100)

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
}
