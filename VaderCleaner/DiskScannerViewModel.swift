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
    /// largest volumes. The terminal value (`1.0`) and the initial-bump
    /// case bypass the gate so the bar definitely reaches full.
    private static let progressUpdateThreshold: Double = 0.005

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

    private let scanner: Scanner
    private let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "DiskScannerViewModel"
    )

    init(scanner: @escaping Scanner) {
        self.scanner = scanner
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
        scanGeneration += 1
        let myGeneration = scanGeneration

        phase = .scanning
        scanProgress = 0
        navigationPath = []

        let divisor = max(1, estimatedFileCount)

        // Wrap the synchronous `progress` callback the scanner will fire
        // off-actor. Each invocation hops to the main actor (so the
        // `@Published` write is serialized with view reads), but only
        // applies the new fraction when:
        //
        //   1. the scan that produced it is still the current one
        //      (`scanGeneration` match — guards against concurrent
        //      `startScan` calls),
        //   2. the phase is still `.scanning` (guards against late
        //      progress writes that would otherwise regress a final
        //      `.ready` state back to a fractional value),
        //   3. the fraction has moved at least `progressUpdateThreshold`
        //      since the last published value, or it's the terminal
        //      `1.0` (throttle — without this a 250 000-file scan would
        //      queue 250 000 main-actor tasks).
        let progressHandler: (Int) -> Void = { [weak self] count in
            let fraction = min(1.0, Double(count) / Double(divisor))
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.scanGeneration == myGeneration else { return }
                guard case .scanning = self.phase else { return }
                if fraction == 1.0 || fraction >= self.scanProgress + Self.progressUpdateThreshold {
                    self.scanProgress = fraction
                }
            }
        }

        do {
            let node = try await scanner(root, progressHandler)
            // Generation-guard the terminal write so a stale scan that
            // resumes after a newer one has started doesn't clobber the
            // newer scan's `.scanning` (or `.ready`) state.
            guard scanGeneration == myGeneration else { return }
            scanProgress = 1.0
            phase = .ready(node)
        } catch is CancellationError {
            // A cancellation is a clean dismissal — the user (or a fresh
            // scan) chose to stop the in-flight walk. Surfacing this as
            // `.error("The operation couldn't be completed…")` would
            // misrepresent it as a failure in the upcoming UI.
            guard scanGeneration == myGeneration else { return }
            scanProgress = 0
            phase = .idle
        } catch {
            guard scanGeneration == myGeneration else { return }
            log.error("Disk scan failed: \(String(describing: error), privacy: .private(mask: .hash))")
            scanProgress = 0
            phase = .error(error.localizedDescription)
        }
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
