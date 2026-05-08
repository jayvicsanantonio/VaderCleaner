// DiskScannerViewModel.swift
// State machine and progress tracker behind Space Lens — drives idle/scanning/ready/error transitions and clamps the injected scanner's progress callbacks into a 0–1 published value.

import Foundation
import os.log

/// Drives the Space Lens detail view. Holds the discrete `Phase` the view
/// switches on, the breadcrumb stack the upcoming treemap UI (Prompt 17)
/// will push/pop, and the running progress value bound to the in-flight
/// scan's progress bar.
///
/// All collaborators are injected — production wires
/// `DiskScannerViewModel.live(...)` through `DiskScanner().scan(...)`,
/// while unit tests inject a closure that returns a synthetic
/// `DiskNode` and drives the progress callback at controlled points.
@MainActor
final class DiskScannerViewModel: ObservableObject {

    /// Type of the injected scan closure. Async + throwing so the
    /// production wiring can wrap `DiskScanner.scan(root:progress:)` and
    /// tests can supply an in-memory tree (or throw to exercise the
    /// failure path). The progress callback is invoked with a running
    /// file count.
    typealias Scanner = (URL, @escaping (Int) -> Void) async throws -> DiskNode

    /// Discrete phases the view binds to. Manual `Equatable` because
    /// `DiskNode` is a class without `Equatable` conformance — the synth
    /// would compile but test fixtures comparing `.ready(node)` snapshots
    /// would always disagree. Identity (`===`) is the right semantic
    /// here: a fresh scan really is a different tree, even if its bytes
    /// match the previous one.
    enum Phase {
        case idle
        case scanning
        case ready(DiskNode)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// 0.0 – 1.0 progress for the currently-running scan. Clamped to 1.0
    /// so an under-estimated `estimatedFileCount` (typical on volumes
    /// with more files than the default heuristic) doesn't push the bar
    /// past full. Resets to 0 when a new scan starts and on `.error`.
    @Published private(set) var scanProgress: Double = 0

    /// Breadcrumb stack the treemap (Prompt 17) will use to record the
    /// user's drill-down path. Kept here because the navigation state
    /// belongs with the scan it's navigating; the helper `drillDown(into:)`
    /// / `navigateUp()` methods land in Prompt 17 alongside the UI that
    /// invokes them.
    @Published var navigationPath: [DiskNode] = []

    /// Convenience accessor used by the upcoming view binding so the
    /// treemap doesn't have to pattern-match on `phase` to find the root.
    var root: DiskNode? {
        if case .ready(let node) = phase { return node }
        return nil
    }

    /// Smallest fractional change worth republishing. A real-volume scan
    /// can fire the progress callback hundreds of thousands of times;
    /// without this gate every call would queue a `Task` on the main
    /// actor and starve the UI thread. 0.5% (200 buckets across the 0–1
    /// range) is fine-grained enough that the bar never visibly jumps
    /// while keeping the queued-task count to a couple hundred for the
    /// largest volumes. The terminal value (`1.0`) bypasses the gate so
    /// the bar definitely reaches full.
    private static let progressUpdateThreshold: Double = 0.005

    /// Reference-typed bucket tracker so the off-actor progress closure
    /// can decide *before* hopping to the main actor whether the new
    /// count crosses the throttle threshold. Without this, the gate ran
    /// inside the queued main-actor task and we still spawned one
    /// `Task` per file — the very behaviour the throttle is meant to
    /// avoid. Single-threaded access: `DiskScanner.buildNode` invokes
    /// the closure from one recursive task chain, so no synchronization
    /// is required.
    private final class ProgressGate {
        var lastScheduledBucket: Int = -1
    }

    /// Monotonically increasing token bumped at the start of every
    /// `startScan`. Late-arriving progress callbacks and the post-scan
    /// final-state assignment both compare against the value captured at
    /// the start of *their* scan; a mismatch means a newer scan has
    /// already started, so the older one's writes are dropped on the
    /// floor. Pairs with the `.scanning` phase guard for defense in
    /// depth — the generation token catches concurrent restarts, the
    /// phase guard catches in-flight progress callbacks that land after
    /// `.ready` / `.error` / `.idle`.
    private var scanGeneration: Int = 0

    /// Handle on the currently-running scan so a fresh `startScan`
    /// (rescan, root switch) can actually cancel the previous walk
    /// instead of just ignoring its eventual writes. Without this the
    /// generation guard kept the UI consistent but `DiskScanner` kept
    /// reading the entire disk in the background, doubling I/O during
    /// the overlap window. `Task.checkCancellation()` inside
    /// `buildNode` honors the cancel at every directory boundary.
    private var currentScanTask: Task<Void, Never>?

    private let scanner: Scanner
    private let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "DiskScannerViewModel"
    )

    init(scanner: @escaping Scanner) {
        self.scanner = scanner
    }

    /// Cancel any in-flight walk if the view-model is torn down while a
    /// scan is running (e.g. the user dismisses Space Lens mid-scan).
    /// `Task.cancel()` is `Sendable`-safe so this is fine to call from a
    /// non-isolated deinit on a `@MainActor` class.
    deinit {
        currentScanTask?.cancel()
    }

    /// Run the injected scanner against `root`. Transitions to `.scanning`
    /// up front, then to `.ready(node)` or `.error(message)` depending on
    /// outcome. The selection / breadcrumb stack is reset because the
    /// previous tree is no longer valid.
    ///
    /// `estimatedFileCount` is the divisor for `scanProgress`. The
    /// scanner doesn't know the total ahead of time (an upfront walk
    /// would double the wall-clock cost), so we settle for an estimate
    /// and clamp the bar at 1.0 once it reaches the ceiling. The bar is
    /// for the user's sense of motion — actual completion is signaled by
    /// the phase landing on `.ready`, not by progress hitting 1.0.
    func startScan(root: URL, estimatedFileCount: Int = 250_000) async {
        // Cancel any walk still in flight from a previous startScan.
        // Cancellation is cooperative — `DiskScanner.buildNode` checks
        // it at every directory boundary and throws `CancellationError`,
        // which the previous Task's catch handler swallows (and the
        // generation guard below ensures it can't clobber our state).
        currentScanTask?.cancel()

        scanGeneration += 1
        let myGeneration = scanGeneration

        phase = .scanning
        scanProgress = 0
        navigationPath = []

        let divisor = max(1, estimatedFileCount)
        // Width (in files) of one throttle bucket. With the default
        // 0.5% threshold and a 250 000-file estimate this is 1 250 —
        // i.e. at most ~200 main-actor Tasks per scan. `ceil` so the
        // bucket is at least 1 even for tiny estimates (the test suite
        // uses divisors of 100 and below).
        let bucketSize = max(1, Int((Double(divisor) * Self.progressUpdateThreshold).rounded(.up)))
        let gate = ProgressGate()

        // Wrap the synchronous `progress` callback the scanner will fire
        // off-actor. The throttle gate runs *here*, before the main-actor
        // hop, so a 250 000-file scan only ever schedules ~200 Tasks
        // (one per crossed bucket plus the terminal write). Each
        // scheduled Task still re-checks generation + phase on the main
        // actor for two defense-in-depth reasons:
        //
        //   1. the scan that produced it must still be the current one
        //      (`scanGeneration` match — guards against concurrent
        //      `startScan` calls), and
        //   2. the phase must still be `.scanning` (guards against late
        //      progress writes that would otherwise regress a final
        //      `.ready` state back to a fractional value).
        let progressHandler: (Int) -> Void = { [weak self] count in
            let bucket = count / bucketSize
            // Schedule only when the bucket advances *or* the count has
            // reached the divisor (terminal — guarantees the bar can
            // reach 1.0 even when the final file lands mid-bucket).
            let isTerminal = count >= divisor
            guard isTerminal || bucket > gate.lastScheduledBucket else { return }
            gate.lastScheduledBucket = bucket
            let fraction = min(1.0, Double(count) / Double(divisor))
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.scanGeneration == myGeneration else { return }
                guard case .scanning = self.phase else { return }
                self.scanProgress = fraction
            }
        }

        // Wrap the scan in a Task we can hold onto, so a future
        // `startScan` (rescan / root switch) can call `cancel()` on
        // it and break out of `DiskScanner.buildNode`. `[weak self]`
        // because the Task's lifetime is bounded by the scan itself,
        // not by the VM — without it, dismissing Space Lens mid-scan
        // would keep the VM alive until the walk finished.
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            do {
                let node = try await self.scanner(root, progressHandler)
                // Generation-guard the terminal write so a stale scan
                // that resumes after a newer one has started doesn't
                // clobber the newer scan's `.scanning` / `.ready` state.
                guard self.scanGeneration == myGeneration else { return }
                self.scanProgress = 1.0
                self.phase = .ready(node)
            } catch is CancellationError {
                // A cancellation is a clean dismissal — the user (or a
                // fresh scan) chose to stop the in-flight walk.
                // Surfacing this as `.error("The operation couldn't be
                // completed…")` would misrepresent it as a failure.
                guard self.scanGeneration == myGeneration else { return }
                self.scanProgress = 0
                self.phase = .idle
            } catch {
                guard self.scanGeneration == myGeneration else { return }
                self.log.error("Disk scan failed: \(String(describing: error), privacy: .private(mask: .hash))")
                self.scanProgress = 0
                self.phase = .error(error.localizedDescription)
            }
        }
        currentScanTask = task
        // Suspend until *this* scan finishes so callers `await
        // vm.startScan(...)` still observe the terminal state on
        // return. The previous (cancelled) task continues winding
        // down in parallel; its catch handler drops its writes via
        // the generation guard.
        await task.value
    }
}

// MARK: - Phase Equatable

/// Manual `Equatable` so the view can use `.onChange(of: phase)` and the
/// test suite can assert exact matches. `.ready` compares by node
/// identity (see the `Phase` doc comment); `.error` compares by message.
extension DiskScannerViewModel.Phase: Equatable {
    static func == (lhs: DiskScannerViewModel.Phase, rhs: DiskScannerViewModel.Phase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.scanning, .scanning):
            return true
        case let (.ready(l), .ready(r)):
            return l === r
        case let (.error(l), .error(r)):
            return l == r
        default:
            return false
        }
    }
}

// MARK: - Production wiring

extension DiskScannerViewModel {

    /// Build a view-model wired to the real `DiskScanner`. Mirrors the
    /// `LargeOldFilesViewModel.live(...)` pattern.
    @MainActor
    static func live() -> DiskScannerViewModel {
        DiskScannerViewModel(scanner: { url, progress in
            try await DiskScanner().scan(root: url, progress: progress)
        })
    }
}
