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
///   - `checkedCategories`: the user's per-category opt-in/out. Defaults to
///     every category present in the latest scan result on each successful
///     `scan()`, so users never have to "select all" before cleaning.
///   - `result`: the most recent `ScanResult`. Held alongside `phase` so
///     toggling a checkbox can recompute `totalSelectedSize` without re-
///     scanning, and so `clean()` can pick the right items to delete.
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
    /// wrap `SystemJunkScanner.scan(excluding:)` and tests can supply an
    /// in-memory `ScanResult` (or throw to exercise the failure path).
    /// Kept non-Sendable: every invocation flows through `@MainActor scan()`,
    /// so the closure body inherits main-actor isolation and there is nothing
    /// to gain by widening the contract.
    typealias Scanner = () async throws -> ScanResult

    /// Closure type for the deletion sink. Returns the number of bytes that
    /// were actually freed (not the byte sum of the input) so partial-failure
    /// cases — e.g. the helper deletes nine of ten paths — are reported
    /// accurately to the user.
    typealias Deleter = ([ScannedFile]) async throws -> Int64

    private(set) var phase: Phase = .idle
    private(set) var checkedCategories: Set<ScanCategory> = []

    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let deleter: Deleter
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

    /// Sum of bytes for every file in a currently-checked category. Computed
    /// from `latestResult.sizeByCategory` (built once when the result lands)
    /// rather than walking `items` per query, so a hot toggle doesn't burn
    /// CPU on hundreds of thousands of file records.
    var totalSelectedSize: Int64 {
        guard let sizes = latestResult?.sizeByCategory else { return 0 }
        return checkedCategories.reduce(into: Int64(0)) { acc, category in
            acc += sizes[category] ?? 0
        }
    }

    /// Convenience for the view layer — formatting once on the VM keeps the
    /// "human-readable size" rule in one place across cards and totals.
    var formattedTotalSelectedSize: String {
        Self.byteFormatter.string(fromByteCount: totalSelectedSize)
    }

    /// Whether `category` is currently checked. The view binds each row's
    /// `Toggle` to `Binding(get:set:)` over `isChecked` + `toggle`.
    func isChecked(_ category: ScanCategory) -> Bool {
        checkedCategories.contains(category)
    }

    /// Run the injected scanner and land in `.preview` (or `.failed`).
    /// Marks every category present in the result as checked so the user is
    /// at "select all" by default.
    func scan() async {
        phase = .scanning
        do {
            let result = try await scanner()
            self.latestResult = result
            self.checkedCategories = Set(result.itemsByCategory.keys)
            self.phase = .preview(result)
        } catch {
            log.error("System Junk scan failed: \(String(describing: error), privacy: .public)")
            self.latestResult = nil
            self.checkedCategories = []
            self.phase = .failed(stage: .scanning, message: error.localizedDescription)
        }
    }

    /// Hand the injected deleter every file in a checked category and land
    /// in `.complete(bytesFreed:)`. A no-op when no category is checked.
    func clean() async {
        guard let result = latestResult, !checkedCategories.isEmpty else { return }
        let toDelete = result.items.filter { checkedCategories.contains($0.category) }
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

    /// Flip the checkbox state for `category`. Idempotent in the sense that
    /// two calls in a row return the VM to its prior selection, by design.
    func toggle(_ category: ScanCategory) {
        if checkedCategories.contains(category) {
            checkedCategories.remove(category)
        } else {
            checkedCategories.insert(category)
        }
    }

    /// Reset the VM to `.idle`, dropping the cached result and selection so
    /// the next scan starts from a clean slate. Called from the "Scan Again"
    /// button on the complete state and the "Re-scan" button on preview.
    func scanAgain() {
        latestResult = nil
        checkedCategories = []
        phase = .idle
    }

    // MARK: - Formatters

    /// Shared `ByteCountFormatter` for the human-readable total. Constructed
    /// once because the formatter allocates measurable internal state per
    /// instance and `formattedTotalSelectedSize` is read on every keystroke /
    /// toggle while the preview list is on screen.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

// MARK: - Production wiring

extension SystemJunkViewModel {

    /// Build a view-model wired to the real `SystemJunkScanner` and a deleter
    /// that splits files between `FileManager` (user-domain) and the
    /// privileged XPC helper (`/Library/Caches`, `/Library/Logs`, mounted-
    /// volume trashes). The exclusions snapshot is captured per scan so a
    /// freshly-added Preferences exclusion takes effect on the very next run.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> SystemJunkViewModel {
        SystemJunkViewModel(
            scanner: { [weak exclusions] in
                // Both `scan()` (the caller) and this closure inherit the
                // enclosing `@MainActor` isolation, so the `exclusions`
                // snapshot can be read directly without an explicit
                // `MainActor.run` hop. The actual file walk happens inside
                // `SystemJunkScanner.scan(excluding:)`, which is async and
                // yields the main actor at its first internal `await`.
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                return try await SystemJunkScanner().scan(excluding: excluded)
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
        // `latestResult` / `checkedCategories` writes interleave. Gate on
        // the in-flight phases, mirroring `SmartScanViewModel.scan()`.
        guard phase != .scanning, phase != .cleaning else { return }
        Task { await scan() }
    }
}
