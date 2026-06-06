// DiskScannerViewModel.swift
// State machine and progress tracker behind Space Lens — drives idle/scanning/ready/error transitions and translates the injected scanner's progress callbacks into a throttled, published walked-file count for the open-ended scanning spinner.

import Foundation
import Observation
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
@Observable
final class DiskScannerViewModel {

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

    private(set) var phase: Phase = .idle

    /// Running count of files the in-flight scan has walked. The disk total
    /// is unknowable mid-walk (an upfront count would double the wall-clock
    /// cost), so Space Lens shows an open-ended indeterminate spinner plus
    /// this live count — the same "Scanned N items…" feedback the other
    /// open-ended scans use — rather than a fraction that would misreport
    /// completion. Completion is signaled by `phase` landing on `.ready`.
    /// Resets to 0 when a new scan starts, on `.error`, and on cancellation.
    private(set) var scannedItemCount: Int = 0

    /// Breadcrumb stack the treemap (Prompt 17) will use to record the
    /// user's drill-down path. Kept here because the navigation state
    /// belongs with the scan it's navigating; the helper `drillDown(into:)`
    /// / `navigateUp()` methods land in Prompt 17 alongside the UI that
    /// invokes them.
    var navigationPath: [DiskNode] = []

    /// Convenience accessor used by the upcoming view binding so the
    /// treemap doesn't have to pattern-match on `phase` to find the root.
    var root: DiskNode? {
        if case .ready(let node) = phase { return node }
        return nil
    }

    /// The node the treemap should currently render — root when the
    /// breadcrumb stack is empty, otherwise the deepest crumb. Returns
    /// `nil` outside the `.ready` phase so the view falls back to its
    /// idle / scanning / error placeholders rather than rendering a
    /// stale tree.
    var currentNode: DiskNode? {
        guard let root else { return nil }
        return navigationPath.last ?? root
    }

    // MARK: - Navigation

    /// Drill into a directory the user clicked. Pushes onto `navigationPath`
    /// so the visualization re-renders the target's contents and the
    /// breadcrumb grows.
    ///
    /// **Records the full ancestor chain.** The treemap's tiles are always
    /// direct children of the current node, but the sunburst surfaces several
    /// rings of descendants at once — tapping a deeper ring hands us a node
    /// that is *not* a direct child. Appending only that node would skip the
    /// folders in between, so the breadcrumb would read `root > descendant`
    /// and `navigateUp` would jump back too far. Instead we append every node
    /// from the current node down to the target. For a direct child this is a
    /// single-element chain, so the treemap path is unchanged.
    ///
    /// **No-op for non-directories** — files have no children, so a
    /// drill-down would land the view on an empty rectangle. Centralising
    /// the guard here means the view layer doesn't have to check before
    /// every click.
    func drillDown(into node: DiskNode) {
        guard node.isDirectory else { return }
        guard let current = currentNode,
              let chain = Self.ancestryChain(from: current, to: node),
              !chain.isEmpty else {
            // `node` is the current node itself (empty chain) or not within its
            // subtree (nil) — nothing new to navigate into.
            return
        }
        navigationPath.append(contentsOf: chain)
    }

    /// The chain of nodes from `ancestor`'s matching child down to `target`
    /// (inclusive), or `nil` when `target` isn't in `ancestor`'s subtree.
    /// Returns an empty array when `target` *is* `ancestor`. Identity-based
    /// (`===`) because two scans produce distinct nodes for the same path
    /// (see the `DiskNode` doc comment).
    private static func ancestryChain(from ancestor: DiskNode, to target: DiskNode) -> [DiskNode]? {
        if ancestor === target { return [] }
        for child in ancestor.children {
            if child === target { return [child] }
            if let deeper = ancestryChain(from: child, to: target) {
                return [child] + deeper
            }
        }
        return nil
    }

    /// Pop the breadcrumb stack by one entry. No-op when already at root,
    /// so the back button can stay enabled without checking
    /// `navigationPath.isEmpty` upstream.
    func navigateUp() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
    }

    /// Empty the breadcrumb stack so the treemap re-renders against the
    /// scan root. Wired to the root crumb in the Space Lens breadcrumb;
    /// kept on the VM (rather than the view writing
    /// `navigationPath = []` directly) so any future side-effects of
    /// jumping to root — telemetry, in-flight cancellation — have a
    /// single hook.
    func navigateToRoot() {
        navigationPath = []
    }

    /// Truncate `navigationPath` so `node` becomes the new tail. Powers
    /// the breadcrumb's "jump to ancestor" affordance — clicking the
    /// third crumb pops back two levels in one gesture.
    ///
    /// **No-op when `node` isn't on the current path** — a stale crumb
    /// reference (e.g. captured in a SwiftUI closure across a rescan)
    /// shouldn't desync the displayed tree. Identity comparison (`===`)
    /// because two snapshots of the same path under different scans are
    /// distinct nodes by design (see `DiskNode` doc comment).
    func navigate(to node: DiskNode) {
        guard let index = navigationPath.firstIndex(where: { $0 === node }) else { return }
        navigationPath = Array(navigationPath.prefix(through: index))
    }

    /// Width of one progress-update bucket, as a fraction of the estimate. A
    /// real-volume scan can fire the progress callback millions of times;
    /// without this gate every call would queue a `Task` on the main actor
    /// and starve the UI thread. The 0.5% bucket width (the estimate divided
    /// into 200 steps) is fine-grained enough that the live count never
    /// visibly stutters, while bounding the queued-task count to (files
    /// processed ÷ bucket width) — ~200 tasks up to the estimate, and a few
    /// thousand for a volume several times larger.
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
    @ObservationIgnored private var scanGeneration: Int = 0

    /// Handle on the currently-running scan so a fresh `startScan`
    /// (rescan, root switch) can actually cancel the previous walk
    /// instead of just ignoring its eventual writes. Without this the
    /// generation guard kept the UI consistent but `DiskScanner` kept
    /// reading the entire disk in the background, doubling I/O during
    /// the overlap window. `Task.checkCancellation()` inside
    /// `buildNode` honors the cancel at every directory boundary.
    @ObservationIgnored private var currentScanTask: Task<Void, Never>?

    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let log = Logger(
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

    /// Stop any in-flight disk walk and return Space Lens to its idle state.
    /// This is used when the main window closes while the app may continue
    /// running from the menu bar: the app-scoped view-model can outlive the
    /// visible UI, so cancellation cannot depend only on `deinit`.
    func cancelScan() {
        currentScanTask?.cancel()
        currentScanTask = nil
        scanGeneration += 1
        if case .scanning = phase {
            scannedItemCount = 0
            phase = .idle
        }
    }

    /// Run the injected scanner against `root`. Transitions to `.scanning`
    /// up front, then to `.ready(node)` or `.error(message)` depending on
    /// outcome. The selection / breadcrumb stack is reset because the
    /// previous tree is no longer valid.
    ///
    /// `estimatedFileCount` only sizes the progress-update throttle bucket
    /// (see `progressUpdateThreshold`) — it is *not* a completion target.
    /// The scan reports an open-ended walked count, not a fraction, so the
    /// estimate being off just makes the count update a little more or less
    /// often; it never caps the count or the scan. Completion is signaled by
    /// the phase landing on `.ready`.
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
        scannedItemCount = 0
        navigationPath = []

        let divisor = max(1, estimatedFileCount)
        // Width (in files) of one throttle bucket. With the default
        // 0.5% threshold and a 250 000-file estimate this is 1 250 —
        // i.e. roughly one main-actor Task per 1 250 files walked. `ceil`
        // so the bucket is at least 1 even for tiny estimates (the test
        // suite uses divisors of 100 and below).
        let bucketSize = max(1, Int((Double(divisor) * Self.progressUpdateThreshold).rounded(.up)))
        let gate = ProgressGate()

        // Wrap the synchronous `progress` callback the scanner will fire
        // off-actor. The throttle gate runs *here*, before the main-actor
        // hop, so the scan schedules at most one Task per crossed bucket
        // for the whole walk, however large the volume. Each scheduled Task
        // still re-checks generation + phase on the main actor for two
        // defense-in-depth reasons:
        //
        //   1. the scan that produced it must still be the current one
        //      (`scanGeneration` match — guards against concurrent
        //      `startScan` calls), and
        //   2. the phase must still be `.scanning` (guards against late
        //      progress writes that would otherwise regress a final
        //      `.ready` state back to a scanning value).
        let progressHandler: (Int) -> Void = { [weak self] count in
            let bucket = count / bucketSize
            guard bucket > gate.lastScheduledBucket else { return }
            gate.lastScheduledBucket = bucket
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.scanGeneration == myGeneration else { return }
                guard case .scanning = self.phase else { return }
                // Drop a hop that landed out of order (the Tasks are
                // unstructured) so the walked count never ticks backwards.
                guard count > self.scannedItemCount else { return }
                self.scannedItemCount = count
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
                self.phase = .ready(node)
            } catch is CancellationError {
                // A cancellation is a clean dismissal — the user (or a
                // fresh scan) chose to stop the in-flight walk.
                // Surfacing this as `.error("The operation couldn't be
                // completed…")` would misrepresent it as a failure.
                guard self.scanGeneration == myGeneration else { return }
                self.scannedItemCount = 0
                self.phase = .idle
            } catch {
                guard self.scanGeneration == myGeneration else { return }
                self.log.error("Disk scan failed: \(String(describing: error), privacy: .private(mask: .hash))")
                self.scannedItemCount = 0
                self.phase = .error(error.localizedDescription)
            }
        }
        currentScanTask = task
        // Suspend until *this* scan finishes so callers `await
        // vm.startScan(...)` still observe the terminal state on
        // return. The previous (cancelled) task continues winding
        // down in parallel; its catch handler drops its writes via
        // the generation guard.
        //
        // The cancellation handler forwards caller-side cancellation
        // to the unstructured scan task — without it, a SwiftUI
        // `.task` torn down on view dismissal would leave the disk
        // walk running. `deinit` can't rescue us here because this
        // `await` keeps `self` alive; the only way out is to cancel
        // the inner task explicitly when the caller is cancelled.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
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
    /// `LargeOldFilesViewModel.live(...)` pattern — the exclusions snapshot
    /// is captured per scan so a freshly-added Preferences exclusion takes
    /// effect on the very next scan.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> DiskScannerViewModel {
        DiskScannerViewModel(scanner: { [weak exclusions] url, progress in
            let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
            return try await DiskScanner().scan(
                root: url,
                excluding: excluded,
                progress: progress
            )
        })
    }
}

// MARK: - ScanCoordinating

extension DiskScannerViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.ready`/`.error` both want the section's own detail UI
    /// (the treemap or the error state), whose internal switch handles each.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning:
            return .working
        case .ready, .error:
            return .results
        }
    }

    func beginScan() {
        // Space Lens needs a root URL its peers don't; the user's home
        // directory is the default Space Lens root for the unified flow.
        Task { await startScan(root: FileManager.default.homeDirectoryForCurrentUser) }
    }
}
