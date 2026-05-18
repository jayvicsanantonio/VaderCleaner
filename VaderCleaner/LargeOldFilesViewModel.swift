// LargeOldFilesViewModel.swift
// State machine, sort order, and selection logic behind the Large & Old Files feature view — drives idle/scanning/results/empty/failed transitions and routes deletions through an injected per-URL deleter.

import Foundation
import os.log

/// Drives the Large & Old Files feature view (scan → results → delete).
///
/// The view-model owns four pieces of state:
///   - `phase`: the current step in the state machine, bound to the view's
///     switch on rendered content.
///   - `displayedFiles`: the post-sort list shown in the table. Recomputed
///     whenever the underlying file list or `sortOrder` changes so the view
///     can bind to one stable property.
///   - `sortOrder`: which column drives the sort. Changing it triggers an
///     in-VM re-sort rather than handing a `KeyPathComparator` to SwiftUI's
///     `Table` — keeps a single ordering rule for selection helpers and
///     future export paths.
///   - `selectedURLs`: the user's current selection. Cleared when the
///     containing files vanish (after delete) so the footer's
///     `totalSelectedSize` is always consistent with the displayed rows.
///
/// All collaborators are injected as closures so unit tests can drive every
/// transition without touching the real filesystem. Production wiring lives
/// in `LargeOldFilesViewModel.live(...)` below.
@MainActor
final class LargeOldFilesViewModel: ObservableObject {

    /// Which step of the flow generated a `.failed` phase, so the view can
    /// pick the right heading. A delete failure must not be reported as
    /// "Couldn't complete the scan" — the scan succeeded; deletion blew up.
    enum FailureStage: Equatable {
        case scanning
        case deleting
    }

    /// Discrete phases the view binds to. `Equatable` so SwiftUI's diffing
    /// avoids redundant re-renders when an incoming value is unchanged.
    enum Phase: Equatable {
        case idle
        case scanning
        case results([ScannedFile])
        case empty
        case failed(stage: FailureStage, message: String)
    }

    /// Sort axes exposed by the view's column-header buttons. `Equatable`
    /// so the view can use `.onChange(of: sortOrder)` if needed.
    enum SortOrder: Equatable {
        case sizeDescending
        case sizeAscending
        case dateAscending
        case dateDescending
        case nameAscending
    }

    /// Closure type for the scan source. Async + throwing so production can
    /// wrap `LargeOldFilesScanner.scan(excluding:)` and tests can supply an
    /// in-memory `[ScannedFile]` (or throw to exercise the failure path).
    typealias Scanner = () async throws -> [ScannedFile]

    /// Closure type for the deletion sink. Returns the set of URLs that were
    /// **actually** removed — partial-failure cases (some files locked,
    /// permission denied, etc.) must report only the URLs that succeeded so
    /// the surviving files stay in the table.
    typealias Deleter = ([URL]) async -> Set<URL>

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selectedURLs: Set<URL> = []

    /// Current sort axis. The setter recomputes `displayedFiles` so the view
    /// table re-orders without the caller doing the work. Defaults to size-
    /// descending — the first row should be the biggest forgotten thing on
    /// disk, which is the entire reason the user opened this feature.
    @Published var sortOrder: SortOrder = .sizeDescending {
        didSet {
            guard oldValue != sortOrder else { return }
            recomputeDisplayedFiles()
        }
    }

    /// Files currently shown in the table, post-sort. Held separately from
    /// `phase` so re-sorting and per-file deletes don't have to round-trip
    /// through a phase-replacement.
    @Published private(set) var displayedFiles: [ScannedFile] = []

    private let scanner: Scanner
    private let deleter: Deleter
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "LargeOldFilesViewModel")

    /// Running total of bytes for files in `selectedURLs`. Maintained
    /// incrementally on every `toggleSelection` so the footer label updates
    /// in O(1) rather than walking `displayedFiles` on every read.
    @Published private(set) var totalSelectedSize: Int64 = 0

    init(scanner: @escaping Scanner, deleter: @escaping Deleter) {
        self.scanner = scanner
        self.deleter = deleter
    }

    // MARK: - Public surface

    /// Whether `file` is currently selected. The view binds each row's
    /// checkbox `Toggle` to `Binding(get:set:)` over `isSelected` +
    /// `toggleSelection`.
    func isSelected(_ file: ScannedFile) -> Bool {
        selectedURLs.contains(file.url)
    }

    /// Flip the selection state for `file` and adjust `totalSelectedSize`
    /// in lockstep. Idempotent in the sense that two calls in a row return
    /// the VM to its prior selection.
    func toggleSelection(_ file: ScannedFile) {
        if selectedURLs.contains(file.url) {
            selectedURLs.remove(file.url)
            totalSelectedSize -= file.size
        } else {
            selectedURLs.insert(file.url)
            totalSelectedSize += file.size
        }
    }

    /// Run the injected scanner and land in `.results`, `.empty`, or
    /// `.failed`. Selection is cleared because the previous list is no
    /// longer valid.
    func scan() async {
        phase = .scanning
        selectedURLs = []
        totalSelectedSize = 0
        do {
            let files = try await scanner()
            applyScanResult(files)
        } catch {
            log.error("Large & Old Files scan failed: \(String(describing: error), privacy: .private(mask: .hash))")
            displayedFiles = []
            phase = .failed(stage: .scanning, message: error.localizedDescription)
        }
    }

    /// Hand the injected deleter the URLs of every currently-selected file
    /// and trim the displayed list down to whatever survives. Transitions
    /// to `.empty` if nothing is left, or stays in `.results` with the
    /// updated array. A no-op when nothing is selected.
    func deleteSelected() async {
        guard !selectedURLs.isEmpty else { return }
        await delete(urls: Array(selectedURLs))
    }

    /// Delete a specific set of URLs (used by the right-click "Delete"
    /// path which targets a single row independent of the broader
    /// selection). Survivors stay in the table; the selection set drops
    /// the deleted URLs but otherwise persists.
    func delete(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let actuallyDeleted = await deleter(urls)
        let survivors = displayedFiles.filter { !actuallyDeleted.contains($0.url) }
        displayedFiles = survivors
        // Drop the deleted URLs from the selection set, then recompute
        // `totalSelectedSize` from scratch. The incremental upkeep in
        // `toggleSelection` only handles user-driven add/remove — deletion
        // removes selected URLs out from under it.
        selectedURLs.subtract(actuallyDeleted)
        totalSelectedSize = displayedFiles
            .filter { selectedURLs.contains($0.url) }
            .reduce(Int64(0)) { $0 + $1.size }
        phase = survivors.isEmpty ? .empty : .results(survivors)
    }

    /// Reset the view-model to `.idle`, dropping the cached results and
    /// selection so the next scan starts from a clean slate. Wired to the
    /// "Scan Again" button on the empty / complete states.
    func scanAgain() {
        displayedFiles = []
        selectedURLs = []
        totalSelectedSize = 0
        phase = .idle
    }

    // MARK: - Internals

    /// Lands the scanner output: empty → `.empty`, otherwise sort and stash
    /// for `.results`. Pulled out so failure recovery and successful scans
    /// share the same "set displayedFiles + emit phase" sequence.
    private func applyScanResult(_ files: [ScannedFile]) {
        if files.isEmpty {
            displayedFiles = []
            phase = .empty
            return
        }
        let sorted = Self.sort(files, by: sortOrder)
        displayedFiles = sorted
        phase = .results(sorted)
    }

    /// Re-sort the displayed list in place using the current `sortOrder`.
    /// Cheap enough to run on every `sortOrder` change; the file count is
    /// bounded by what the scanner emitted (typically dozens to low
    /// thousands) and `Array.sorted` is O(n log n).
    private func recomputeDisplayedFiles() {
        guard !displayedFiles.isEmpty else { return }
        displayedFiles = Self.sort(displayedFiles, by: sortOrder)
        if case .results = phase {
            phase = .results(displayedFiles)
        }
    }

    /// Stable sort that puts `nil` access dates last under date-based
    /// orderings — files we can't reason about by age shouldn't crowd out
    /// the meaningful entries. For non-date orderings, `nil` dates are
    /// irrelevant and the comparator never inspects them.
    private static func sort(_ files: [ScannedFile], by order: SortOrder) -> [ScannedFile] {
        switch order {
        case .sizeDescending:
            return files.sorted { $0.size > $1.size }
        case .sizeAscending:
            return files.sorted { $0.size < $1.size }
        case .nameAscending:
            return files.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .dateAscending:
            return files.sorted { lhs, rhs in
                switch (lhs.lastAccessDate, rhs.lastAccessDate) {
                case (nil, nil): return false
                case (nil, _):   return false   // nil sorts after non-nil
                case (_, nil):   return true    // non-nil sorts before nil
                case let (l?, r?): return l < r
                }
            }
        case .dateDescending:
            return files.sorted { lhs, rhs in
                switch (lhs.lastAccessDate, rhs.lastAccessDate) {
                case (nil, nil): return false
                case (nil, _):   return false   // nil sorts after non-nil
                case (_, nil):   return true    // non-nil sorts before nil
                case let (l?, r?): return l > r
                }
            }
        }
    }
}

// MARK: - Production wiring

extension LargeOldFilesViewModel {

    /// Build a view-model wired to the real `LargeOldFilesScanner` plus a
    /// `FileManager`-backed deleter. Mirrors `SystemJunkViewModel.live(...)`
    /// — the exclusions snapshot is captured per scan so a freshly-added
    /// Preferences exclusion takes effect on the very next run.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> LargeOldFilesViewModel {
        LargeOldFilesViewModel(
            scanner: { [weak exclusions] in
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                return try await LargeOldFilesScanner().scan(excluding: excluded)
            },
            deleter: { urls in
                await Self.removeUserFiles(at: urls)
            }
        )
    }

    /// Default deleter: walk each URL through `FileManager.removeItem` and
    /// return the set of URLs whose deletion succeeded. Failures are logged
    /// and skipped — a single locked file must never abort the whole batch,
    /// and the surviving files stay in the table so the user can retry.
    ///
    /// Marked `nonisolated` so the synchronous `FileManager.removeItem`
    /// loop runs off the main actor — without this annotation a static
    /// member on a `@MainActor`-isolated class inherits main-actor
    /// isolation, which would block the UI for the duration of a multi-
    /// gigabyte delete batch.
    private nonisolated static func removeUserFiles(at urls: [URL]) async -> Set<URL> {
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "LargeOldFilesViewModel.Deleter")
        var deleted: Set<URL> = []
        let manager = FileManager.default
        for url in urls {
            do {
                try manager.removeItem(at: url)
                deleted.insert(url)
            } catch {
                // Both the path and the error message can carry user-
                // identifying info (full filesystem paths, locale-specific
                // error descriptions); redact both with hash-masked
                // private privacy so OSLog displays consistent placeholders
                // outside the user's own machine.
                log.debug(
                    "Skipping unremovable user file \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        return deleted
    }
}

// MARK: - ScanCoordinating

extension LargeOldFilesViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.results`/`.empty`/`.failed` all want the section's own
    /// detail UI, whose internal switch renders the specifics.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning:
            return .working
        case .results, .empty, .failed:
            return .results
        }
    }

    func beginScan() {
        Task { await scan() }
    }
}
