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
        phase = .scanning
        scanProgress = 0
        navigationPath = []

        let divisor = max(1, estimatedFileCount)

        // Wrap the synchronous `progress` callback the scanner will fire
        // off-actor. Hopping each update through a `MainActor` task keeps
        // `scanProgress` updates serialized — without this hop the
        // `@Published` write would race with view reads.
        let progressHandler: (Int) -> Void = { [weak self] count in
            let fraction = min(1.0, Double(count) / Double(divisor))
            Task { @MainActor [weak self] in
                self?.scanProgress = fraction
            }
        }

        do {
            let node = try await scanner(root, progressHandler)
            // Yield once so any in-flight progress updates the scanner
            // enqueued via `Task { @MainActor … }` finish applying before
            // we stamp the final 1.0. Without this, the last fractional
            // progress write could land *after* our explicit 1.0 below
            // and leave the bar visibly short of full.
            await Task.yield()
            scanProgress = 1.0
            phase = .ready(node)
        } catch {
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
