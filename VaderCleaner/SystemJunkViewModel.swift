// SystemJunkViewModel.swift
// State machine and selection logic behind the System Junk feature view — drives idle/scanning/preview/cleaning/complete transitions and routes the user's category selection through an injected deleter.

import Foundation
import Observation
import os.log

/// Drives the System Junk feature view (scan → preview → clean → done).
///
/// The view-model owns four pieces of state:
///   - `phase`: the current step in the state machine, bound to the view's
///     switch on rendered content.
///   - `selectedURLs`: the user's per-file opt-in/out. Defaults to every file
///     present in the latest scan result on each successful `scan()`, so users
///     never have to "select all" before cleaning — junk is safe to remove, so
///     selection is opt-out, not opt-in.
///   - `result`: the most recent `ScanResult`. Held alongside `phase` so
///     toggling a row can recompute `totalSelectedSize` without re-scanning,
///     and so `clean()` can pick the right items to delete.
///   - `errorMessage`: the surfaced description for the `.failed` phase.
///
/// All collaborators are injected as closures so unit tests can drive every
/// transition without touching the real filesystem or the privileged XPC
/// helper. Production wiring lives in `SystemJunkViewModel.live(...)` below.
@MainActor
@Observable
final class SystemJunkViewModel {

    /// Which step of the flow generated a `.failed` phase, so the view can
    /// pick the right heading. `clean()` failure must not surface as
    /// "Couldn't complete the scan" — the scan succeeded; deletion blew up.
    enum FailureStage: Equatable {
        case scanning
        case cleaning
    }

    /// Discrete phases the System Junk view binds to. Equatable so tests can
    /// pin exact transitions and SwiftUI's `Equatable`-aware diffing avoids
    /// redundant re-renders when an incoming value is unchanged.
    enum Phase: Equatable {
        case idle
        case scanning
        case preview(ScanResult)
        case cleaning
        case complete(bytesFreed: Int64)
        case failed(stage: FailureStage, message: String)
    }

    /// Closure type for the scan source. Async + throwing so production can
    /// wrap `SystemJunkScanner.scan(excluding:onProgress:)` and tests can
    /// supply an in-memory `ScanResult` (or throw to exercise the failure
    /// path). The outer closure stays non-Sendable — every invocation flows
    /// through `@MainActor scan()` — while the `@Sendable (Int) -> Void`
    /// parameter receives the running walked-item count from the scanner's
    /// background walk so the scanning screen can show it advancing.
    typealias Scanner = (@escaping @Sendable (Int) -> Void) async throws -> ScanResult

    /// Closure type for the deletion sink. Returns the number of bytes that
    /// were actually freed (not the byte sum of the input) so partial-failure
    /// cases — e.g. the helper deletes nine of ten paths — are reported
    /// accurately to the user.
    typealias Deleter = ([ScannedFile]) async throws -> Int64

    private(set) var phase: Phase = .idle

    /// URLs of the files the user has selected for cleaning. Defaults to every
    /// file in the latest scan on success (opt-out), and is cleared on
    /// `scanAgain()`. The view binds each review row's checkbox to
    /// `isSelected` + `toggleSelection`.
    private(set) var selectedURLs: Set<URL> = []

    /// Running total of bytes for files in `selectedURLs`. Maintained
    /// incrementally on every `toggleSelection` so the footer label updates in
    /// O(1) rather than walking the (potentially large) result on every read.
    private(set) var totalSelectedSize: Int64 = 0

    /// Per-category running total of selected bytes, maintained in lockstep with
    /// `totalSelectedSize`. Lets the Cleanup Manager's per-category "selected"
    /// badge read in O(1) instead of reducing over every file in the category on
    /// every render — the walk that beachballed switching between categories on
    /// large scans.
    private(set) var selectedBytesByCategory: [ScanCategory: Int64] = [:]

    /// Per-category running count of selected files, maintained in lockstep with
    /// `selectedBytesByCategory`. Lets the Cleanup Manager's "Select:
    /// None/All/Some" bulk menu read its state in O(1) instead of scanning every
    /// row (and every file beneath each folder row) on each render — the walk
    /// that delayed the checkbox repaint on large scans.
    private(set) var selectedCountByCategory: [ScanCategory: Int] = [:]

    /// Running count of filesystem items the in-flight scan has walked. Reset
    /// to 0 at the start of each scan and fed by the scanner's progress
    /// callback so the scanning screen can show "Scanned N items…" — proof the
    /// open-ended walk is advancing rather than hung.
    private(set) var scannedItemCount: Int = 0

    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let deleter: Deleter

    /// Incremented at the start of every scan so a progress tick that hops back
    /// to the main actor after a newer scan began is dropped rather than
    /// corrupting the fresh count.
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "SystemJunkViewModel")

    /// Cached most-recent scan result. Held so checkbox toggles can recompute
    /// `totalSelectedSize` cheaply, and so `clean()` knows which items to
    /// hand to the deleter.
    @ObservationIgnored private var latestResult: ScanResult?

    init(scanner: @escaping Scanner, deleter: @escaping Deleter) {
        self.scanner = scanner
        self.deleter = deleter
    }

    // MARK: - Public surface

    /// Whether `file` is currently selected. The view binds each review row's
    /// `Toggle` to `Binding(get:set:)` over `isSelected` + `toggleSelection`.
    func isSelected(_ file: ScannedFile) -> Bool {
        selectedURLs.contains(file.url)
    }

    /// Selected bytes in one category — an O(1) read backing the Cleanup
    /// Manager's per-category selected-size badge.
    func selectedBytes(in category: ScanCategory) -> Int64 {
        selectedBytesByCategory[category] ?? 0
    }

    /// Selected file count in one category — an O(1) read backing the Cleanup
    /// Manager's per-category bulk-select menu state.
    func selectedCount(in category: ScanCategory) -> Int {
        selectedCountByCategory[category] ?? 0
    }

    /// Flip the selection state for `file` and adjust `totalSelectedSize` in
    /// lockstep. Idempotent in the sense that two calls in a row return the VM
    /// to its prior selection.
    func toggleSelection(_ file: ScannedFile) {
        if selectedURLs.contains(file.url) {
            selectedURLs.remove(file.url)
            totalSelectedSize -= file.size
            selectedBytesByCategory[file.category, default: 0] -= file.size
            selectedCountByCategory[file.category, default: 0] -= 1
        } else {
            selectedURLs.insert(file.url)
            totalSelectedSize += file.size
            selectedBytesByCategory[file.category, default: 0] += file.size
            selectedCountByCategory[file.category, default: 0] += 1
        }
    }

    /// Whether every file in `files` is currently selected. Short-circuits on
    /// the first unselected file, so the common "nothing selected yet" case is
    /// O(1). Backs the folder-row checkbox's checked state and its all-or-
    /// nothing toggle target.
    func areAllSelected(_ files: [ScannedFile]) -> Bool {
        !files.isEmpty && files.allSatisfy { selectedURLs.contains($0.url) }
    }

    /// Toggle a whole group of files as one unit — the Cleanup Manager's
    /// folder-row checkbox, which covers every file beneath a folder. If the
    /// group is already fully selected it's cleared; otherwise the whole group
    /// is selected (so a partially-selected folder fills in).
    func toggleSelection(_ files: [ScannedFile]) {
        setSelection(files, selected: !areAllSelected(files))
    }

    /// Select or clear a whole group of files in a single pass, writing each
    /// observable property exactly once. Toggling a folder that covers tens of
    /// thousands of files went through `toggleSelection(_ file:)` per file,
    /// which re-acquired the store lock, re-hashed each URL several times, and
    /// fired four observation mutations *per file* — the work that froze the UI
    /// for seconds on large folders. Building the new values on local copies and
    /// assigning once collapses that to four mutations total.
    func setSelection(_ files: [ScannedFile], selected: Bool) {
        guard !files.isEmpty else { return }
        var urls = selectedURLs
        var total = totalSelectedSize
        var bytes = selectedBytesByCategory
        var counts = selectedCountByCategory
        for file in files {
            if selected {
                guard urls.insert(file.url).inserted else { continue }
                total += file.size
                bytes[file.category, default: 0] += file.size
                counts[file.category, default: 0] += 1
            } else {
                guard urls.remove(file.url) != nil else { continue }
                total -= file.size
                bytes[file.category, default: 0] -= file.size
                counts[file.category, default: 0] -= 1
            }
        }
        selectedURLs = urls
        totalSelectedSize = total
        selectedBytesByCategory = bytes
        selectedCountByCategory = counts
    }

    /// Replace the selection with every file in `categories` — backs a
    /// dashboard card's "Review", which opens the manager with that card's whole
    /// group pre-selected. The resulting `totalSelectedSize` therefore matches
    /// the card's displayed size.
    func selectOnly(categories: Set<ScanCategory>) {
        guard let result = latestResult else { return }
        var urls: Set<URL> = []
        var total: Int64 = 0
        var bytesByCategory: [ScanCategory: Int64] = [:]
        var countByCategory: [ScanCategory: Int] = [:]
        for file in result.items where categories.contains(file.category) {
            urls.insert(file.url)
            total += file.size
            bytesByCategory[file.category, default: 0] += file.size
            countByCategory[file.category, default: 0] += 1
        }
        selectedURLs = urls
        totalSelectedSize = total
        selectedBytesByCategory = bytesByCategory
        selectedCountByCategory = countByCategory
    }

    /// Run the injected scanner and land in `.preview` (or `.failed`).
    /// Selects every file present in the result so the user is at "select all"
    /// by default.
    func scan() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        phase = .scanning
        scannedItemCount = 0
        do {
            let result = try await scanner { [weak self] count in
                // The scanner runs off the main actor; hop back before touching
                // the observable count, and drop ticks from a superseded scan.
                Task { @MainActor in
                    // Drop the tick if a newer scan started, if the scan has
                    // already left `.scanning` (a late tick must not re-trigger
                    // observation once the preview is showing), or if it would
                    // move the monotonic walked count backwards (the hops are
                    // unstructured, so they can land out of order).
                    guard let self,
                          self.scanGeneration == generation,
                          case .scanning = self.phase,
                          count > self.scannedItemCount else { return }
                    self.scannedItemCount = count
                }
            }
            self.latestResult = result
            // Nothing is selected by default — the user opts in to what to
            // clean in the Cleanup Manager.
            self.selectedURLs = []
            self.totalSelectedSize = 0
            self.selectedBytesByCategory = [:]
            self.selectedCountByCategory = [:]
            self.phase = .preview(result)
        } catch {
            log.error("System Junk scan failed: \(String(describing: error), privacy: .public)")
            self.latestResult = nil
            self.selectedURLs = []
            self.totalSelectedSize = 0
            self.selectedBytesByCategory = [:]
            self.selectedCountByCategory = [:]
            self.phase = .failed(stage: .scanning, message: error.localizedDescription)
        }
    }

    /// Adopt a result produced by a Smart Scan (same `SystemJunkScanner`, same
    /// scope) so the user lands on the preview without scanning again. No-op
    /// unless idle, so it never overwrites an in-progress or already-shown scan.
    /// Mirrors `scan()`'s success path: select every file by default.
    func seed(with result: ScanResult) {
        guard case .idle = phase else { return }
        latestResult = result
        // Match `scan()`: start with nothing selected so the user opts in.
        selectedURLs = []
        totalSelectedSize = 0
        selectedBytesByCategory = [:]
        selectedCountByCategory = [:]
        phase = .preview(result)
    }

    /// Hand the injected deleter every currently-selected file and land in
    /// `.complete(bytesFreed:)`. A no-op when nothing is selected.
    func clean() async {
        guard let result = latestResult, !selectedURLs.isEmpty else { return }
        let toDelete = result.items.filter { selectedURLs.contains($0.url) }
        await performClean(toDelete)
    }

    /// Clean every file whose category is in `categories`, regardless of the
    /// per-file selection — backs a dashboard card's "Clean" button, which acts
    /// on the whole group. A no-op when the group produced no files.
    func clean(categories: Set<ScanCategory>) async {
        guard let result = latestResult else { return }
        let toDelete = result.items.filter { categories.contains($0.category) }
        await performClean(toDelete)
    }

    /// Shared clean pipeline: a no-op for an empty input, otherwise
    /// `.cleaning` → `.complete(bytesFreed:)`, or `.failed` if the deleter
    /// throws. `bytesFreed` comes from the deleter so partial-failure cases
    /// report what was actually removed, not the requested total.
    private func performClean(_ toDelete: [ScannedFile]) async {
        guard !toDelete.isEmpty else { return }

        phase = .cleaning
        do {
            let bytes = try await deleter(toDelete)
            self.phase = .complete(bytesFreed: bytes)
        } catch {
            log.error("System Junk clean failed: \(String(describing: error), privacy: .public)")
            self.phase = .failed(stage: .cleaning, message: error.localizedDescription)
        }
    }

    /// Reset the VM to `.idle`, dropping the cached result and selection so
    /// the next scan starts from a clean slate. Called from the "Scan Again"
    /// button on the complete state and the "Re-scan" button on the dashboard.
    func scanAgain() {
        latestResult = nil
        selectedURLs = []
        totalSelectedSize = 0
        selectedBytesByCategory = [:]
        selectedCountByCategory = [:]
        scannedItemCount = 0
        phase = .idle
    }

}

// MARK: - Production wiring

extension SystemJunkViewModel {

    /// Build a view-model wired to the real `SystemJunkScanner` and a deleter
    /// that splits files between `FileManager` (user-domain) and the
    /// privileged XPC helper (`/Library/Caches`, `/Library/Logs`, mounted-
    /// volume trashes). The exclusions snapshot is captured per scan so a
    /// freshly-added Preferences exclusion takes effect on the very next run.
    @MainActor
    static func live(
        exclusions: ExclusionsStore,
        webDevScanScope: WebDevScanScopeStore? = nil
    ) -> SystemJunkViewModel {
        SystemJunkViewModel(
            scanner: { [weak exclusions, weak webDevScanScope] onProgress in
                // Both `scan()` (the caller) and this closure inherit the
                // enclosing `@MainActor` isolation, so the `exclusions`
                // snapshot can be read directly without an explicit
                // `MainActor.run` hop. The actual file walk happens inside
                // `SystemJunkScanner.scan(excluding:onProgress:)`, which is
                // async and yields the main actor at its first internal
                // `await`; `onProgress` is forwarded so the walked-item count
                // reaches the scanning screen.
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                // The Web Development Junk project-scan roots are snapshotted
                // here too, so a folder picked in Settings takes effect on the
                // next scan.
                let projectRoots = webDevScanScope?.scanRoots
                return try await SystemJunkScanner.live(projectScanRoots: projectRoots)
                    .scan(excluding: excluded, onProgress: onProgress)
            },
            deleter: { files in
                try await SystemJunkDeleter().delete(files)
            }
        )
    }
}

// MARK: - ScanCoordinating

extension SystemJunkViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.scanning`/`.cleaning` are both "work in flight";
    /// `.preview`/`.complete`/`.failed` all want the section's own detail UI,
    /// whose internal switch renders the specifics.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning, .cleaning:
            return .working
        case .preview, .complete, .failed:
            return .results
        }
    }

    func beginScan() {
        // `scan()` has no internal re-entrancy guard, so a double-tapped
        // unified Scan button could race two concurrent disk walks whose
        // `latestResult` / `selectedURLs` writes interleave. Gate on the
        // in-flight phases, mirroring `SmartScanViewModel.scan()`.
        guard phase != .scanning, phase != .cleaning else { return }
        Task { await scan() }
    }
}
