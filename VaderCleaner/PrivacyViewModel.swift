// PrivacyViewModel.swift
// State machine and selection logic behind the Privacy feature view — drives idle/scanning/preview/clearing/complete transitions and routes the user's per-browser per-category selection through an injected clearer plus a recent-files manager.

import Foundation
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
final class PrivacyViewModel: ObservableObject {

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

    typealias Detector             = () async throws -> [Browser]
    typealias Sizer                = (Browser, PrivacyCategory) -> Int64
    typealias PathsResolver        = (Browser, PrivacyCategory) -> [URL]
    typealias Clearer              = (Browser, PrivacyCategory) async throws -> Void
    typealias RecentFilesClearer   = () async throws -> Void

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detectedBrowsers: [Browser] = []
    @Published private(set) var checkedSelections: Set<Selection> = []
    @Published private(set) var isClearRecentsChecked: Bool = true

    private let detector: Detector
    private let sizer: Sizer
    private let pathsFor: PathsResolver
    private let clearer: Clearer
    private let clearRecentFiles: RecentFilesClearer
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "PrivacyViewModel")

    /// Cached per-cell sizes, populated at the end of `preview()` so the
    /// view's row labels and `totalSelectedSize` compute in O(1).
    private var sizesByBrowserCategory: [Selection: Int64] = [:]

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
                let paths = pathsFor(browser, category)
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

    // MARK: - Actions

    /// Run detection + sizing and land in `.preview` (or `.failed`).
    /// Marks every detected `(browser, category)` checked by default
    /// (and the recent-items toggle on) so the user is at "select all".
    func preview() async {
        phase = .scanning
        do {
            let browsers = try await detector()
            var sizes: [Selection: Int64] = [:]
            var checked: Set<Selection> = []
            for browser in browsers {
                for category in PrivacyCategory.allCases {
                    let selection = Selection(browser: browser, category: category)
                    sizes[selection] = sizer(browser, category)
                    checked.insert(selection)
                }
            }
            self.detectedBrowsers = browsers
            self.sizesByBrowserCategory = sizes
            self.checkedSelections = checked
            self.isClearRecentsChecked = true
            self.phase = .preview
        } catch {
            // Log error description as `.private` — `error.localizedDescription`
            // can include user-specific filesystem paths or browser
            // profile names, which we don't want in unredacted unified-
            // log output of a Privacy feature.
            log.error("Privacy preview failed: \(String(describing: error), privacy: .private)")
            self.detectedBrowsers = []
            self.sizesByBrowserCategory = [:]
            self.checkedSelections = []
            self.phase = .failed(stage: .scanning, message: error.localizedDescription)
        }
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
        phase = .clearing
        do {
            if isClearRecentsChecked {
                try await clearRecentFiles()
            }
            // Iterate selections in a deterministic
            // (browser × category) order so a mid-run failure aborts at
            // a predictable point — `Set` iteration order is undefined,
            // which would make retries and bug reports inconsistent.
            for selection in orderedCheckedSelections() {
                try await clearer(selection.browser, selection.category)
            }
            self.phase = .complete(bytesFreed: bytesPlanned)
        } catch {
            // See `preview()` — same reasoning for `.private`.
            log.error("Privacy clear failed: \(String(describing: error), privacy: .private)")
            self.phase = .failed(stage: .clearing, message: error.localizedDescription)
        }
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
        detectedBrowsers = []
        checkedSelections = []
        sizesByBrowserCategory = [:]
        isClearRecentsChecked = true
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
                clearer.previewSize(for: category, browser: browser)
            },
            pathsFor: { browser, category in
                clearer.paths(for: category, browser: browser)
            },
            clearer: { browser, category in
                try clearer.clear(category: category, browser: browser)
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
