// PrivacyViewModel.swift
// State machine and selection logic behind the Privacy feature view — drives idle/scanning/preview/clearing/complete transitions and routes the user's per-browser per-category selection through an injected clearer plus a recent-files manager.

import Foundation
import Observation
import os.log

/// Drives the Privacy feature view (preview → clear → done).
///
/// The view-model owns:
///   - `phase`: the current step in the state machine, bound to the
///     view's switch on rendered content.
///   - `detectedBrowsers`: the set of browsers the detector reported as
///     installed at the last preview.
///   - `checkedSelections`: per-browser per-category opt-in/out.
///   - `isClearRecentsChecked`: top-level toggle for the recent-items
///     clear action, separate from browser selections.
///   - `sizesByBrowserCategory`: cached per-cell sizes computed once at
///     preview time so the view's row labels don't trigger fresh I/O on
///     every redraw.
///
/// Every collaborator is injected as a closure so unit tests can drive
/// every transition without touching real disk state. Production wiring
/// lives in `PrivacyViewModel.live(...)`.
@MainActor
@Observable
final class PrivacyViewModel {

    /// Which step of the flow generated a `.failed` phase, so the view can
    /// pick the right heading. Mirrors `SystemJunkViewModel.FailureStage`.
    enum FailureStage: Equatable {
        case scanning
        case clearing
    }

    /// Discrete phases the Privacy view binds to.
    enum Phase: Equatable {
        case idle
        case scanning
        case preview
        case clearing
        case complete(bytesFreed: Int64)
        case failed(stage: FailureStage, message: String)
    }

    /// Composite key for the `(browser, category)` selection set.
    struct Selection: Hashable {
        let browser: Browser
        let category: PrivacyCategory
    }

    typealias Detector             = @Sendable () async throws -> [Browser]
    typealias Sizer                = @Sendable (Browser, PrivacyCategory) async throws -> Int64
    typealias PathsResolver        = @Sendable (Browser, PrivacyCategory) -> [URL]
    typealias Clearer              = @Sendable (Browser, PrivacyCategory) async throws -> Void
    typealias RecentFilesClearer   = @MainActor @Sendable () async throws -> Void

    private(set) var phase: Phase = .idle
    private(set) var detectedBrowsers: [Browser] = []
    private(set) var checkedSelections: Set<Selection> = []
    private(set) var isClearRecentsChecked: Bool = true

    @ObservationIgnored private let detector: Detector
    @ObservationIgnored private let sizer: Sizer
    @ObservationIgnored private let pathsFor: PathsResolver
    @ObservationIgnored private let clearer: Clearer
    @ObservationIgnored private let clearRecentFiles: RecentFilesClearer
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "PrivacyViewModel")

    /// Monotonically increasing token for preview / clear work. When a
    /// newer operation starts, older tasks can still finish winding down,
    /// but they must not publish stale results back into the UI.
    @ObservationIgnored private var operationGeneration: Int = 0

    /// Handle for the currently-running Privacy operation. A new preview,
    /// clear, reset, or view-model teardown cancels the old one so expensive
    /// browser-data filesystem work does not keep competing in the
    /// background after the user has moved on.
    @ObservationIgnored private var currentOperationTask: Task<Void, Never>?

    /// Cached per-cell sizes, populated at the end of `preview()` so the
    /// view's row labels and `totalSelectedSize` compute in O(1).
    @ObservationIgnored private var sizesByBrowserCategory: [Selection: Int64] = [:]

    /// Cached per-cell paths, populated alongside preview sizes so SwiftUI
    /// rendering and checkbox toggles don't synchronously resolve browser
    /// profile directories on the main actor.
    @ObservationIgnored private var pathsByBrowserCategory: [Selection: [URL]] = [:]

    init(
        detector: @escaping Detector,
        sizer: @escaping Sizer,
        pathsFor: @escaping PathsResolver,
        clearer: @escaping Clearer,
        clearRecentFiles: @escaping RecentFilesClearer
    ) {
        self.detector = detector
        self.sizer = sizer
        self.pathsFor = pathsFor
        self.clearer = clearer
        self.clearRecentFiles = clearRecentFiles
    }

    deinit {
        currentOperationTask?.cancel()
    }

    // MARK: - Public surface

    /// Sum of bytes for every checked selection, deduplicated by URL —
    /// Chromium / Firefox `.history` and `.downloads` share a SQLite file,
    /// so a naive `sum(sizesByBrowserCategory[selected])` would double-
    /// count on those browsers.
    var totalSelectedSize: Int64 {
        sumOfSizes(over: checkedSelections)
    }

    /// Whether `(browser, category)` is currently checked. The view
    /// binds each row's `Toggle` to this getter + `toggle(browser:category:)`.
    func isChecked(browser: Browser, category: PrivacyCategory) -> Bool {
        checkedSelections.contains(Selection(browser: browser, category: category))
    }

    /// Per-cell size for the row label.
    func size(for browser: Browser, category: PrivacyCategory) -> Int64 {
        sizesByBrowserCategory[Selection(browser: browser, category: category)] ?? 0
    }

    /// Sum of sizes for every category of `browser` regardless of
    /// selection — used by the disclosure-group header to show a per-
    /// browser total even when the group is collapsed.
    func sizeOnDisk(for browser: Browser) -> Int64 {
        let allSelections = PrivacyCategory.allCases.map {
            Selection(browser: browser, category: $0)
        }
        return sumOfSizes(over: Set(allSelections))
    }

    /// Whether `(browser, category)` has any on-disk paths the clearer
    /// can act on. Returns `false` for cells that are intentionally
    /// no-ops at the file level — Chromium / Firefox `.downloads` is
    /// the canonical case (download history lives inside the same
    /// SQLite as browsing history; a path-based clear of just
    /// downloads would also wipe history). The view uses this to
    /// render those rows as informational ("Included with Browsing
    /// History") rather than as a checkbox the user can toggle, so
    /// the UI never claims to do something it can't.
    func isCategoryActionable(browser: Browser, category: PrivacyCategory) -> Bool {
        !paths(for: browser, category: category).isEmpty
    }

    /// Currently-checked selections in a stable
    /// `Browser.allCases` × `PrivacyCategory.allCases` order. Used by
    /// `clear()` to make the destructive loop deterministic — a `Set`
    /// would order-shuffle between runs and make partial-failure
    /// retries inconsistent.
    func orderedCheckedSelections() -> [Selection] {
        var result: [Selection] = []
        for browser in Browser.allCases {
            for category in PrivacyCategory.allCases {
                let selection = Selection(browser: browser, category: category)
                if checkedSelections.contains(selection) {
                    result.append(selection)
                }
            }
        }
        return result
    }

    /// Path-deduped size sum across an arbitrary selection set. Cells
    /// whose paths overlap (Chromium / Firefox `.history` and
    /// `.downloads` share a SQLite file) contribute the cell size *once*.
    /// Cells with no paths contribute 0 — they're either unreachable
    /// (e.g. Firefox without a profile yet) or a no-op category that
    /// the production clearer handles as such.
    private func sumOfSizes(over selections: Set<Selection>) -> Int64 {
        var visitedPaths = Set<URL>()
        var total: Int64 = 0
        // Iterate in `Browser.allCases` × `PrivacyCategory.allCases`
        // order so dedup is deterministic — Set iteration order is not
        // stable, and the test expectation depends on `.history` being
        // visited before `.downloads`.
        for browser in Browser.allCases {
            for category in PrivacyCategory.allCases {
                let selection = Selection(browser: browser, category: category)
                guard selections.contains(selection) else { continue }
                let paths = paths(for: browser, category: category)
                guard !paths.isEmpty else { continue }
                let firstUnseen = paths.first { !visitedPaths.contains($0) }
                if firstUnseen != nil {
                    total += sizesByBrowserCategory[selection] ?? 0
                }
                for path in paths { visitedPaths.insert(path) }
            }
        }
        return total
    }

    private func paths(for browser: Browser, category: PrivacyCategory) -> [URL] {
        let selection = Selection(browser: browser, category: category)
        return pathsByBrowserCategory[selection] ?? pathsFor(browser, category)
    }

    // MARK: - Actions

    /// Run detection + sizing and land in `.preview` (or `.failed`).
    /// Marks every detected `(browser, category)` checked by default
    /// (and the recent-items toggle on) so the user is at "select all".
    func preview() async {
        let generation = beginOperation()
        phase = .scanning
        let detector = detector
        let sizer = sizer
        let pathsFor = pathsFor
        let log = log

        let task = Task.detached {
            do {
                let browsers = try await detector()
                var sizes: [Selection: Int64] = [:]
                var pathsBySelection: [Selection: [URL]] = [:]
                var checked: Set<Selection> = []
                for browser in browsers {
                    for category in PrivacyCategory.allCases {
                        try Task.checkCancellation()
                        let selection = Selection(browser: browser, category: category)
                        sizes[selection] = try await sizer(browser, category)
                        pathsBySelection[selection] = pathsFor(browser, category)
                        checked.insert(selection)
                    }
                }
                try Task.checkCancellation()
                let sizesSnapshot = sizes
                let pathsSnapshot = pathsBySelection
                let checkedSnapshot = checked
                await MainActor.run { [weak self] in
                    guard let self, self.operationGeneration == generation else { return }
                    self.detectedBrowsers = browsers
                    self.sizesByBrowserCategory = sizesSnapshot
                    self.pathsByBrowserCategory = pathsSnapshot
                    self.checkedSelections = checkedSnapshot
                    self.isClearRecentsChecked = true
                    self.phase = .preview
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.operationGeneration == generation else { return }
                    self.clearPreviewState()
                    self.phase = .idle
                }
            } catch {
                // Log error description as `.private` — `error.localizedDescription`
                // can include user-specific filesystem paths or browser
                // profile names, which we don't want in unredacted unified-
                // log output of a Privacy feature.
                log.error("Privacy preview failed: \(String(describing: error), privacy: .private)")
                await MainActor.run { [weak self] in
                    guard let self, self.operationGeneration == generation else { return }
                    self.detectedBrowsers = []
                    self.sizesByBrowserCategory = [:]
                    self.pathsByBrowserCategory = [:]
                    self.checkedSelections = []
                    self.phase = .failed(stage: .scanning, message: error.localizedDescription)
                }
            }
        }

        currentOperationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishOperation(generation)
    }

    /// Start a new operation by cancelling the old one and invalidating any
    /// late-arriving writes it might try to publish.
    private func beginOperation() -> Int {
        currentOperationTask?.cancel()
        operationGeneration += 1
        return operationGeneration
    }

    /// Clear the operation handle only if it still belongs to the task that
    /// just completed. A newer operation will have advanced the generation.
    private func finishOperation(_ generation: Int) {
        if operationGeneration == generation {
            currentOperationTask = nil
        }
    }

    /// Cancel work without immediately replacing it. Used by `scanAgain()`
    /// so the reset state wins even if a background task completes later.
    private func cancelCurrentOperation() {
        currentOperationTask?.cancel()
        currentOperationTask = nil
        operationGeneration += 1
    }

    /// Clear cached preview state while preserving the current phase choice.
    private func clearPreviewState() {
        detectedBrowsers = []
        checkedSelections = []
        sizesByBrowserCategory = [:]
        pathsByBrowserCategory = [:]
        isClearRecentsChecked = true
    }

    /// Hand each checked selection to the injected clearer and (when the
    /// recents toggle is on) invoke the recent-files clearer. Lands in
    /// `.complete(bytesFreed:)` reporting the pre-clear total — see the
    /// test on `clear_transitionsToCompleteWithBytesFreed` for the
    /// rationale on optimistic accounting.
    ///
    /// Ordering: clear recents first, then browsers. A recents failure
    /// leaves all browser data intact and the user can retry without
    /// hitting "browser shows 0 B because we already wiped it last time"
    /// confusion. A browser failure after recents succeeded is the lesser
    /// evil — recent items is a small list versus potentially gigabytes
    /// of browser data.
    func clear() async {
        guard phase == .preview else { return }
        let bytesPlanned = totalSelectedSize
        let shouldClearRecents = isClearRecentsChecked
        let selections = orderedCheckedSelections()
        let generation = beginOperation()
        phase = .clearing
        let clearRecentFiles = clearRecentFiles
        let clearer = clearer
        let log = log

        let task = Task {
            do {
                if shouldClearRecents {
                    try await clearRecentFiles()
                }
                // Iterate selections in a deterministic
                // (browser × category) order so a mid-run failure aborts at
                // a predictable point — `Set` iteration order is undefined,
                // which would make retries and bug reports inconsistent.
                for selection in selections {
                    try Task.checkCancellation()
                    try await clearer(selection.browser, selection.category)
                }
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.operationGeneration == generation else { return }
                    self.phase = .complete(bytesFreed: bytesPlanned)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.operationGeneration == generation else { return }
                    // Some browser data may already have been cleared, but
                    // keeping the selection visible is the least surprising
                    // recovery path for a retry or manual adjustment.
                    self.phase = .preview
                }
            } catch {
                // See `preview()` — same reasoning for `.private`.
                log.error("Privacy clear failed: \(String(describing: error), privacy: .private)")
                await MainActor.run { [weak self] in
                    guard let self, self.operationGeneration == generation else { return }
                    self.phase = .failed(stage: .clearing, message: error.localizedDescription)
                }
            }
        }

        currentOperationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishOperation(generation)
    }

    /// Flip the per-cell checkbox.
    func toggle(browser: Browser, category: PrivacyCategory) {
        let selection = Selection(browser: browser, category: category)
        if checkedSelections.contains(selection) {
            checkedSelections.remove(selection)
        } else {
            checkedSelections.insert(selection)
        }
    }

    /// Flip the recent-items toggle.
    func toggleClearRecents() {
        isClearRecentsChecked.toggle()
    }

    /// Reset to `.idle`, dropping cached preview state.
    func scanAgain() {
        cancelCurrentOperation()
        clearPreviewState()
        phase = .idle
    }
}

// MARK: - Production wiring

extension PrivacyViewModel {

    /// Build a view-model wired to the real `BrowserDetector`,
    /// `BrowserDataClearer`, and `RecentFilesManager`. No exclusions
    /// filtering — see issue #38 plan comment for the rationale.
    @MainActor
    static func live() -> PrivacyViewModel {
        let detector = DefaultBrowserDetector()
        let pathProvider = DefaultBrowserDataPathProvider()
        let clearer = BrowserDataClearer(pathProvider: pathProvider)
        let recents = RecentFilesManager()

        return PrivacyViewModel(
            detector: { detector.installedBrowsers() },
            sizer: { browser, category in
                try await clearer.previewSize(for: category, browser: browser)
            },
            pathsFor: { browser, category in
                clearer.paths(for: category, browser: browser)
            },
            clearer: { browser, category in
                try await clearer.clear(category: category, browser: browser)
            },
            clearRecentFiles: {
                // `RecentFilesManager` is `@MainActor`, and this closure
                // inherits the enclosing `@MainActor` isolation, so we can
                // call it directly without an explicit hop.
                try recents.clear()
            }
        )
    }
}

// MARK: - ScanCoordinating

extension PrivacyViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.scanning`/`.clearing` are both "work in flight";
    /// `.preview`/`.complete`/`.failed` all want the section's own detail UI,
    /// whose internal switch renders the specifics.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning, .clearing:
            return .working
        case .preview, .complete, .failed:
            return .results
        }
    }

    /// Entrypoint for the unified floating Scan button. Privacy's scan is the
    /// browser-detection + sizing pass that `preview()` runs.
    func beginScan() {
        // `preview()` cancels any in-flight operation before restarting, so a
        // double-tapped Scan button wouldn't race — but gating on the
        // work-in-flight phases keeps the behavior identical to the other
        // scannable view models.
        guard phase != .scanning, phase != .clearing else { return }
        Task { await preview() }
    }
}
