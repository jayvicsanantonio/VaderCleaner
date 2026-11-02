// MyClutterViewModel.swift
// Orchestrates the four My Clutter scans (duplicates, similar images, large & old files, downloads) against the chosen folder, holds their results plus a unified selection, and routes deletions to the Trash.

import Foundation
import Observation
import AppKit
import os.log

/// Section coordinator for My Clutter. Runs four independent scans concurrently
/// and exposes their results to the four-card dashboard. Selection is unified
/// across every category as a single set of URLs (with a precomputed size map)
/// so any review screen can toggle items and the footer total stays correct.
///
/// Collaborators are injected as closures so unit tests drive every transition
/// without touching the filesystem; production wiring lives in `live(...)`.
@MainActor
@Observable
public final class MyClutterViewModel {

    /// Discrete phases the section detail view binds to.
    public enum Phase: Equatable {
        case idle
        case scanning
        case results
        case empty
        case failed(message: String)
    }

    /// The four scan sources, each async + throwing so production wraps the real
    /// scanners and tests supply in-memory results. The progress parameter
    /// receives that scanner's running walked-item count.
    typealias DuplicateScan = @Sendable (@escaping @Sendable (Int) -> Void) async throws -> [DuplicateGroup]
    typealias SimilarScan = @Sendable (@escaping @Sendable (Int) -> Void) async throws -> [SimilarImageGroup]
    typealias LargeOldScan = @Sendable (@escaping @Sendable (Int) -> Void) async throws -> [ScannedFile]
    typealias DownloadsScan = @Sendable (@escaping @Sendable (Int) -> Void) async throws -> [DownloadItem]
    /// Deletion sink. Returns the URLs actually moved to the Trash; survivors
    /// stay in the dashboard.
    typealias Deleter = ([URL]) async -> Set<URL>
    /// Reports that a finished scan surfaced large & old files, with how many and
    /// their combined size. Production routes this to the notification monitor,
    /// which owns the "large or forgotten files" preference and its cooldown; a
    /// nil handler means nothing is notified.
    public typealias LargeOldFilesFoundHandler = @MainActor (_ count: Int, _ totalSize: Int64) -> Void

    public private(set) var phase: Phase = .idle
    public private(set) var scannedItemCount = 0

    public private(set) var duplicateGroups: [DuplicateGroup] = []
    public private(set) var similarGroups: [SimilarImageGroup] = []
    public private(set) var largeOldFiles: [ScannedFile] = []
    public private(set) var downloads: [DownloadItem] = []

    /// Unified deletion selection across every category, keyed by URL.
    public private(set) var selectedURLs: Set<URL> = []
    private(set) var totalSelectedSize: Int64 = 0

    /// Per-category running totals of selected bytes and count, maintained in
    /// lockstep with `selectedURLs`. Let the manager's Large & Old "Selected"
    /// facet and per-category footer read in O(1) instead of reducing over the
    /// (potentially huge) file list on every render — the walk that lagged
    /// switching facets/categories on large scans.
    private(set) var selectedBytesByCategory: [MyClutterCategory: Int64] = [:]
    private(set) var selectedCountByCategory: [MyClutterCategory: Int] = [:]

    /// The categories each reviewable URL belongs to. A file can appear in more
    /// than one (e.g. a large file that is also a duplicate copy), and each
    /// category's totals count it independently — matching the manager's
    /// per-category facet reduces. Rebuilt when a scan completes.
    @ObservationIgnored private var categoriesByURL: [URL: [MyClutterCategory]] = [:]

    /// Bumped whenever the result *set* changes (scan completes, files
    /// trashed) — never on a selection toggle. The manager keys its off-main
    /// cache rebuild to this so it recomputes facets/groups only when the data
    /// actually changes, not on every checkbox click.
    public private(set) var resultsVersion = 0

    /// True while a removal is on its way to the Trash, so the manager can hold
    /// Remove rather than start a second one over the same files.
    public private(set) var isRemoving = false

    /// How many files the last removal could not move to the Trash. They stay
    /// listed and checked, so without this a failure looks like nothing happened.
    /// Cleared by the next selection change or removal.
    public private(set) var removalFailureCount = 0

    /// Size of every reviewable file, so selection totals never re-walk the
    /// result arrays. Rebuilt when a scan completes.
    @ObservationIgnored private var sizeByURL: [URL: Int64] = [:]

    @ObservationIgnored private let duplicateScan: DuplicateScan
    @ObservationIgnored private let similarScan: SimilarScan
    @ObservationIgnored private let largeOldScan: LargeOldScan
    @ObservationIgnored private let downloadsScan: DownloadsScan
    @ObservationIgnored private let deleter: Deleter
    @ObservationIgnored private let onLargeOldFilesFound: LargeOldFilesFoundHandler?
    @ObservationIgnored private var scanGeneration = 0

    /// Whether a review has opened since the scan, which replaces the scan-time
    /// seed: the seed is what a card offers, not what "Review All" opens with.
    @ObservationIgnored private var hasBegunReview = false

    /// Whether the duplicate copies' checkmarks are the user's now, either from
    /// the Duplicates card's one seeding or from their own edits. Reopening a
    /// review must never re-check a copy they chose to keep.
    @ObservationIgnored private var duplicateSelectionIsSettled = false

    /// How many of this scan's sub-scans failed outright, and the last reason —
    /// the evidence behind "part of this couldn't be checked" as opposed to
    /// "nothing was found". Reset at the start of every scan.
    @ObservationIgnored private var failedSubScanCount = 0
    @ObservationIgnored private var subScanFailureMessage: String?

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "MyClutterViewModel")

    init(
        duplicateScan: @escaping DuplicateScan,
        similarScan: @escaping SimilarScan,
        largeOldScan: @escaping LargeOldScan,
        downloadsScan: @escaping DownloadsScan,
        deleter: @escaping Deleter,
        onLargeOldFilesFound: LargeOldFilesFoundHandler? = nil
    ) {
        self.duplicateScan = duplicateScan
        self.similarScan = similarScan
        self.largeOldScan = largeOldScan
        self.downloadsScan = downloadsScan
        self.deleter = deleter
        self.onLargeOldFilesFound = onLargeOldFilesFound
    }

    // MARK: - Derived totals

    // Derived read-model for the dashboard, memoized so a render never pays an
    // O(all-files) cost. Each value is recomputed once, in `recomputeDerived()`,
    // whenever the result set changes (scan completion or a deletion prune) —
    // never on a view render. Before this, the dashboard rebuilt the full
    // `flatMap` copy arrays (hundreds of thousands of elements on a large scan)
    // several times per frame during the section-open animation, which read as
    // a beach-balled main thread before the grid appeared.

    /// Redundant copies across the duplicate groups — the deletion candidates.
    public private(set) var duplicateCopies: [ScannedFile] = []
    /// Redundant near-duplicates across the similar-image groups.
    public private(set) var similarCopies: [ScannedFile] = []
    /// Total files the user can sort through — the count shown in the header.
    public private(set) var totalFileCount: Int = 0
    public private(set) var duplicateReclaimableBytes: Int64 = 0
    public private(set) var similarReclaimableBytes: Int64 = 0
    public private(set) var largeOldBytes: Int64 = 0
    public private(set) var downloadsBytes: Int64 = 0
    /// The browser/app that contributed the most download bytes, for the card
    /// title (e.g. "Google Chrome"), or `nil` for a generic label.
    public private(set) var dominantDownloadSource: String? = nil
    /// The bundle id of the dominant download source, for its app icon on the
    /// dashboard card.
    public private(set) var dominantDownloadBundleID: String? = nil

    /// Rebuild the memoized dashboard read-model from the current result set.
    /// Called only when the source groups/arrays change (scan completion or a
    /// prune), so the O(all-files) work happens once per result change rather
    /// than once per render.
    private func recomputeDerived() {
        duplicateCopies = duplicateGroups.flatMap { $0.redundantCopies }
        similarCopies = similarGroups.flatMap { $0.redundantCopies }
        totalFileCount = duplicateCopies.count + similarCopies.count
            + largeOldFiles.count + downloads.count
        duplicateReclaimableBytes = duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        similarReclaimableBytes = similarGroups.reduce(0) { $0 + $1.reclaimableBytes }
        largeOldBytes = largeOldFiles.reduce(0) { $0 + $1.size }
        downloadsBytes = downloads.reduce(0) { $0 + $1.file.size }
        let source = DownloadsScanner.dominantSource(of: downloads)
        dominantDownloadSource = source
        dominantDownloadBundleID = source.flatMap { name in
            downloads.first { $0.sourceApp == name }?.sourceBundleID
        }
    }

    // MARK: - Selection

    public func isSelected(_ url: URL) -> Bool { selectedURLs.contains(url) }

    /// Selected bytes within one category — an O(1) read backing the manager's
    /// Large & Old "Selected" facet and per-category footer.
    public func selectedBytes(in category: MyClutterCategory) -> Int64 {
        selectedBytesByCategory[category] ?? 0
    }

    /// Selected file count within one category — an O(1) read for the footer.
    public func selectedCount(in category: MyClutterCategory) -> Int {
        selectedCountByCategory[category] ?? 0
    }

    /// Adjust the per-category running totals for one URL's selection change.
    /// A no-op for a URL with no recorded categories.
    private func adjustCategoryTotals(for url: URL, selected: Bool) {
        let size = sizeByURL[url] ?? 0
        for category in categoriesByURL[url] ?? [] {
            selectedBytesByCategory[category, default: 0] += selected ? size : -size
            selectedCountByCategory[category, default: 0] += selected ? 1 : -1
        }
    }

    /// Only URLs the scan actually offers for review may be selected.
    ///
    /// The image strip wires a checkbox to *every* file in a group, including
    /// the kept original — which is deliberately absent from the size/category
    /// index. Selecting one used to render a checked box that contributed no
    /// bytes, no category tally, and nothing to Remove, and then survived every
    /// prune. Gating here makes that contradiction unrepresentable rather than
    /// something four totals each have to shrug off.
    private func isReviewable(_ url: URL) -> Bool {
        categoriesByURL[url] != nil
    }

    public func toggleSelection(url: URL) {
        guard isReviewable(url) else { return }
        noteSelectionEdit(of: url)
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
            totalSelectedSize -= sizeByURL[url] ?? 0
            adjustCategoryTotals(for: url, selected: false)
        } else {
            selectedURLs.insert(url)
            totalSelectedSize += sizeByURL[url] ?? 0
            adjustCategoryTotals(for: url, selected: true)
        }
    }

    /// Prepare the selection for opening the manager: `category` is the card whose
    /// Review was pressed, `nil` is "Review All Files".
    ///
    /// The first review of a scan drops the scan-time seed, so deleting is an
    /// explicit opt-in. The Duplicates card then checks its copies once, because
    /// a copy always leaves the same bytes behind. Everything else opens as the
    /// user left it: reopening must not undo their choices, and other categories'
    /// checkmarks can't leak into a removal because Remove is scoped to the
    /// category on screen. Similar images look alike but are different files, and
    /// Large & Old and Downloads are real user data, so those cards check nothing.
    public func beginReview(of category: MyClutterCategory?) {
        if !hasBegunReview {
            hasBegunReview = true
            clearSelection()
        }
        guard category == .duplicates, !duplicateSelectionIsSettled else { return }
        duplicateSelectionIsSettled = true
        applySelection(duplicateCopies.map(\.url), selected: true)
    }

    private func clearSelection() {
        selectedURLs = []
        totalSelectedSize = 0
        selectedBytesByCategory = [:]
        selectedCountByCategory = [:]
    }

    /// Make `url` the copy a group keeps, with the current original becoming a
    /// removable copy in its place. The checkmark moves too: if `url` was going to
    /// be removed, the old original now is, so the count stays what the user saw.
    /// `url` ends up unchecked everywhere, even if it is also listed in another
    /// category, since they just said they want it. A no-op unless `url` is a
    /// removable copy in that category.
    public func keep(_ url: URL, in category: MyClutterCategory) {
        let previous: ScannedFile
        switch category {
        case .duplicates:
            guard let index = duplicateGroups.firstIndex(where: { Self.isCopy(url, in: $0.files) }) else { return }
            previous = duplicateGroups[index].original
            duplicateGroups[index] = DuplicateGroup(files: Self.moved(url, toFrontOf: duplicateGroups[index].files))
            duplicateSelectionIsSettled = true
        case .similar:
            guard let index = similarGroups.firstIndex(where: { Self.isCopy(url, in: $0.files) }) else { return }
            previous = similarGroups[index].original
            similarGroups[index] = SimilarImageGroup(files: Self.moved(url, toFrontOf: similarGroups[index].files))
        case .largeOld, .downloads:
            return
        }
        recomputeDerived()

        categoriesByURL[url]?.removeAll { $0 == category }
        if categoriesByURL[url]?.isEmpty == true {
            categoriesByURL[url] = nil
            sizeByURL[url] = nil
        }
        sizeByURL[previous.url] = previous.size
        categoriesByURL[previous.url, default: []].append(category)

        if selectedURLs.remove(url) != nil {
            selectedURLs.insert(previous.url)
        }
        totalSelectedSize = selectedURLs.reduce(Int64(0)) { $0 + (sizeByURL[$1] ?? 0) }
        recomputeSelectedCategoryTotals()
    }

    private static func isCopy(_ url: URL, in files: [ScannedFile]) -> Bool {
        files.dropFirst().contains { $0.url == url }
    }

    private static func moved(_ url: URL, toFrontOf files: [ScannedFile]) -> [ScannedFile] {
        files.filter { $0.url == url } + files.filter { $0.url != url }
    }

    /// Bulk select/clear a set of URLs (the review manager's "Select" menu).
    public func setSelection(_ urls: [URL], selected: Bool) {
        for url in urls where isReviewable(url) { noteSelectionEdit(of: url) }
        applySelection(urls, selected: selected)
    }

    private func applySelection(_ urls: [URL], selected: Bool) {
        for url in urls where isReviewable(url) {
            let already = selectedURLs.contains(url)
            if selected, !already {
                selectedURLs.insert(url)
                totalSelectedSize += sizeByURL[url] ?? 0
                adjustCategoryTotals(for: url, selected: true)
            } else if !selected, already {
                selectedURLs.remove(url)
                totalSelectedSize -= sizeByURL[url] ?? 0
                adjustCategoryTotals(for: url, selected: false)
            }
        }
    }

    /// Records a change the user made, which ends any shown removal failure and,
    /// for a duplicate copy, makes those checkmarks theirs.
    private func noteSelectionEdit(of url: URL) {
        removalFailureCount = 0
        if categoriesByURL[url]?.contains(.duplicates) == true {
            duplicateSelectionIsSettled = true
        }
    }

    // MARK: - Scan

    /// Run all four scans concurrently and land in `.results`, `.empty`, or
    /// `.failed`. A single scanner throwing doesn't sink the others — its
    /// category is simply empty — so the dashboard always shows what succeeded.
    /// With nothing to show, though, a failure is the answer: part of the Mac went
    /// unchecked, so it can't be reported as tidy.
    public func scan() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        phase = .scanning
        scannedItemCount = 0
        failedSubScanCount = 0
        subScanFailureMessage = nil
        resetResults()

        let progress = ProgressAggregator()
        let onProgress: @Sendable (Int) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scanGeneration == generation, case .scanning = self.phase else { return }
                let total = await progress.total()
                if total > self.scannedItemCount { self.scannedItemCount = total }
            }
        }
        func report(_ source: Int) -> @Sendable (Int) -> Void {
            { count in
                Task { await progress.set(source: source, count: count); onProgress(count) }
            }
        }

        async let dups = runCatching { try await self.duplicateScan(report(0)) } ?? []
        async let sims = runCatching { try await self.similarScan(report(1)) } ?? []
        async let larges = runCatching { try await self.largeOldScan(report(2)) } ?? []
        async let dls = runCatching { try await self.downloadsScan(report(3)) } ?? []

        let (d, s, l, w) = await (dups, sims, larges, dls)
        guard scanGeneration == generation else { return }
        // Falling through would land `.empty`, whose screen tells the user
        // "Nothing to clean up" — an all-clear stated as fact about a scan that
        // couldn't look everywhere it should have.
        if d.isEmpty, s.isEmpty, l.isEmpty, w.isEmpty, let message = subScanFailureMessage {
            log.error("My Clutter scan failed: \(self.failedSubScanCount, privacy: .public) sub-scans errored and nothing was found")
            phase = .failed(message: message)
            return
        }
        // Build the selection + size/category read-model off the main actor —
        // hashing every URL of a large result on main froze the scan-complete
        // transition (see MyClutterSelectionSeed) — then re-check the
        // generation: a scan restarted during the hop must not have its state
        // clobbered by this one's seed.
        let seed = await MyClutterSelectionSeed.safeDefaults(
            duplicates: d, similar: s, largeOld: l, downloads: w
        )
        guard scanGeneration == generation else { return }
        applyResults(duplicates: d, similar: s, largeOld: l, downloads: w, seed: seed)
    }

    /// Reset to `.idle`, dropping cached results and selection. Wired to "Start
    /// Over" / the empty state's rescan. Bumps the generation so a scan or
    /// removal still running can't write its late results over the reset.
    public func scanAgain() {
        scanGeneration &+= 1
        resetResults()
        scannedItemCount = 0
        phase = .idle
    }

    /// Move the current selection to the Trash and prune the survivors back into
    /// every category. A no-op when nothing is selected.
    func deleteSelected() async {
        await remove(Array(selectedURLs))
    }

    /// Trash only the selected files that fall within `scope` — the category
    /// currently shown in the manager — leaving other categories' selections
    /// intact. Keeps the manager's footer total and its Remove action scoped to
    /// the category the user is reviewing.
    public func deleteSelected(in scope: Set<URL>) async {
        await remove(Array(selectedURLs.intersection(scope)))
    }

    /// Sends `urls` to the Trash and prunes what moved. If the scan was restarted
    /// while this ran, its results are gone and the outcome has nothing to apply
    /// to, so it is dropped rather than written over the new state.
    private func remove(_ urls: [URL]) async {
        guard !urls.isEmpty, !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        removalFailureCount = 0
        let generation = scanGeneration
        let actuallyDeleted = await deleter(urls)
        guard scanGeneration == generation else { return }
        removalFailureCount = Set(urls).subtracting(actuallyDeleted).count
        guard !actuallyDeleted.isEmpty else { return }
        prune(deleted: actuallyDeleted)
    }

    // MARK: - Internals

    private func resetResults() {
        duplicateGroups = []
        similarGroups = []
        largeOldFiles = []
        downloads = []
        selectedURLs = []
        totalSelectedSize = 0
        selectedBytesByCategory = [:]
        selectedCountByCategory = [:]
        sizeByURL = [:]
        categoriesByURL = [:]
        hasBegunReview = false
        duplicateSelectionIsSettled = false
        removalFailureCount = 0
        recomputeDerived()
    }

    private func applyResults(
        duplicates: [DuplicateGroup],
        similar: [SimilarImageGroup],
        largeOld: [ScannedFile],
        downloads: [DownloadItem],
        seed: MyClutterSelectionSeed
    ) {
        self.duplicateGroups = duplicates
        self.similarGroups = similar
        self.largeOldFiles = largeOld
        self.downloads = downloads

        recomputeDerived()
        // The selection and the size/category read-model were precomputed off
        // the main actor from these same results (safe-by-default: redundant
        // copies pre-checked, large/old files and downloads unchecked — see
        // MyClutterSelectionSeed). Applying them here is O(1) per field, so
        // scan completion costs no per-URL hashing on the main thread.
        sizeByURL = seed.sizeByURL
        categoriesByURL = seed.categoriesByURL
        selectedURLs = seed.selectedURLs
        totalSelectedSize = seed.totalSelectedSize
        selectedBytesByCategory = seed.selectedBytesByCategory
        selectedCountByCategory = seed.selectedCountByCategory

        resultsVersion &+= 1
        phase = totalFileCount == 0 ? .empty : .results

        // Announce the large & old findings once the results are settled, so the
        // banner reports the same totals the dashboard is about to show. Nothing
        // found means nothing to say.
        if !largeOldFiles.isEmpty {
            onLargeOldFilesFound?(largeOldFiles.count, largeOldBytes)
        }
    }

    private func rebuildSizeMap() {
        var map: [URL: Int64] = [:]
        var categories: [URL: [MyClutterCategory]] = [:]
        for file in duplicateCopies {
            map[file.url] = file.size
            categories[file.url, default: []].append(.duplicates)
        }
        for file in similarCopies {
            map[file.url] = file.size
            categories[file.url, default: []].append(.similar)
        }
        for file in largeOldFiles {
            map[file.url] = file.size
            categories[file.url, default: []].append(.largeOld)
        }
        for item in downloads {
            map[item.file.url] = item.file.size
            categories[item.file.url, default: []].append(.downloads)
        }
        sizeByURL = map
        categoriesByURL = categories
    }

    /// Rebuild the per-category selected totals from the current selection and
    /// category membership. Used after a deletion prunes the result set.
    private func recomputeSelectedCategoryTotals() {
        var bytes: [MyClutterCategory: Int64] = [:]
        var count: [MyClutterCategory: Int] = [:]
        for url in selectedURLs {
            let size = sizeByURL[url] ?? 0
            for category in categoriesByURL[url] ?? [] {
                bytes[category, default: 0] += size
                count[category, default: 0] += 1
            }
        }
        selectedBytesByCategory = bytes
        selectedCountByCategory = count
    }

    private func prune(deleted: Set<URL>) {
        duplicateGroups = duplicateGroups.compactMap { group in
            let survivors = group.files.filter { !deleted.contains($0.url) }
            return survivors.count > 1 ? DuplicateGroup(files: survivors) : nil
        }
        similarGroups = similarGroups.compactMap { group in
            let survivors = group.files.filter { !deleted.contains($0.url) }
            return survivors.count > 1 ? SimilarImageGroup(files: survivors) : nil
        }
        largeOldFiles.removeAll { deleted.contains($0.url) }
        downloads.removeAll { deleted.contains($0.file.url) }

        // Rebuild the memoized read-model before `rebuildSizeMap()` (which reads
        // `duplicateCopies` / `similarCopies`) and the phase check below.
        recomputeDerived()
        rebuildSizeMap()
        // Intersected with the rebuilt index, not merely stripped of `deleted`:
        // a URL that has left the reviewable set (its group collapsed) must not
        // linger in the selection.
        selectedURLs = selectedURLs.subtracting(deleted).filter { isReviewable($0) }
        totalSelectedSize = selectedURLs.reduce(Int64(0)) { $0 + (sizeByURL[$1] ?? 0) }
        recomputeSelectedCategoryTotals()
        resultsVersion &+= 1
        phase = totalFileCount == 0 ? .empty : .results
    }

    /// Runs a throwing scan, logging and swallowing failures so one scanner
    /// can't sink the dashboard. Returns `nil` on failure (mapped to `[]` by
    /// the caller's `?? []`).
    ///
    /// A real error is also tallied, so `scan()` can tell a Mac with nothing to
    /// sort through from one where nothing could be looked at. Cancellation is
    /// deliberately not counted: the caller is going away, which is no evidence
    /// that anything is broken.
    private func runCatching<T>(_ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch is CancellationError {
            return nil
        } catch {
            log.error("My Clutter sub-scan failed: \(String(describing: error), privacy: .private(mask: .hash))")
            failedSubScanCount += 1
            subScanFailureMessage = error.localizedDescription
            return nil
        }
    }
}

/// Sums per-source walked counts off the main actor so the four concurrent
/// scans can report one aggregate "items scanned" figure.
private actor ProgressAggregator {
    private var counts: [Int: Int] = [:]
    func set(source: Int, count: Int) { counts[source] = count }
    func total() -> Int { counts.values.reduce(0, +) }
}

// MARK: - ScanCoordinating

extension MyClutterViewModel: ScanCoordinating {
    public var scanPresentation: ScanPresentation {
        switch phase {
        case .idle: return .intro
        case .scanning: return .working
        case .results, .empty, .failed: return .results
        }
    }

    public func beginScan() {
        guard phase != .scanning else { return }
        runScanActivity { await self.scan() }
    }
}

// MARK: - Production wiring

extension MyClutterViewModel {

    /// Build a view-model wired to the real scanners. The exclusions snapshot
    /// and the chosen scan folder are captured per scan, so a freshly-added
    /// exclusion or a just-picked folder takes effect on the next run.
    @MainActor
    public static func live(
        exclusions: ExclusionsStore,
        scanScope: MyClutterScanScopeStore,
        onLargeOldFilesFound: LargeOldFilesFoundHandler? = nil
    ) -> MyClutterViewModel {
        MyClutterViewModel(
            // Each closure snapshots the stores on the main actor (their
            // isolation) before starting its walk, still once per scan — so the
            // "picked up on the next run" behaviour above is unchanged.
            duplicateScan: { [weak exclusions, weak scanScope] onProgress in
                let (ex, roots, picked) = await MainActor.run {
                    (Self.clutterExclusions(exclusions), Self.clutterContentRoots(scope: scanScope), scanScope?.scanRoots)
                }
                try Self.requireAvailable(picked)
                return try await DuplicateScanner(roots: roots).scan(excluding: ex, onProgress: onProgress)
            },
            similarScan: { [weak exclusions, weak scanScope] onProgress in
                let (ex, roots, picked) = await MainActor.run {
                    (Self.clutterExclusions(exclusions), Self.clutterContentRoots(scope: scanScope), scanScope?.scanRoots)
                }
                try Self.requireAvailable(picked)
                return try await SimilarImageScanner(roots: roots).scan(excluding: ex, onProgress: onProgress)
            },
            largeOldScan: { [weak exclusions, weak scanScope] onProgress in
                let (ex, roots) = await MainActor.run {
                    (
                        (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) },
                        scanScope?.scanRoots ?? nil
                    )
                }
                try Self.requireAvailable(roots)
                let provider = DefaultUserFilesPathProvider(roots: roots)
                return try await LargeOldFilesScanner(pathProvider: provider).scan(excluding: ex, onProgress: onProgress)
            },
            downloadsScan: { [weak exclusions, weak scanScope] onProgress in
                let (ex, picked) = await MainActor.run {
                    (
                        (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) },
                        scanScope?.scanRoots
                    )
                }
                try Self.requireAvailable(picked)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                let root = Self.downloadsRoot(scanRoots: picked, downloads: downloads)
                return try await DownloadsScanner(downloadsURL: root).scan(excluding: ex, onProgress: onProgress)
            },
            deleter: { urls in await UserFileRecycler.recycle(urls, context: "My Clutter") },
            onLargeOldFilesFound: onLargeOldFilesFound
        )
    }

    /// Throws when a folder the user picked can no longer be read. The walker
    /// tolerates unreadable paths, so without this a renamed folder or unplugged
    /// drive scans as nothing and reads as a tidy Mac. `nil` is the home scope,
    /// whose standard folders may legitimately not all exist.
    private nonisolated static func requireAvailable(_ picked: [URL]?) throws {
        for root in picked ?? [] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: root.path)
            else {
                throw MyClutterScanError.folderUnavailable(name: root.lastPathComponent)
            }
        }
    }

    /// Where the Downloads scan should walk: all of Downloads for the home scope,
    /// and otherwise only the part of it inside the folder the user picked — all
    /// of it if they picked Downloads or a parent, just the subfolder if they
    /// picked inside it, and `nil` (no walk) if they picked somewhere else.
    nonisolated static func downloadsRoot(scanRoots: [URL]?, downloads: URL?) -> URL? {
        guard let scanRoots else { return downloads }
        guard let downloads else { return nil }
        let downloadsPath = ClutterCandidateFilter.comparablePath(downloads)
        for root in scanRoots {
            let rootPath = ClutterCandidateFilter.comparablePath(root)
            if rootPath == downloadsPath { return downloads }
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if downloadsPath.hasPrefix(rootPrefix) { return downloads }
            if rootPath.hasPrefix(downloadsPath + "/") { return root }
        }
        return nil
    }

    /// The user-content folders the duplicate and similar-image scans walk.
    /// A picked folder is scanned directly; the home scope uses the curated
    /// content subtrees and deliberately omits `~/Library` — its caches and
    /// app-support blobs are System Junk's domain, and walking them (then
    /// reading bytes to hash or feature-print) is ruinously slow and not
    /// "clutter" the user sorts through.
    private static func clutterContentRoots(scope: MyClutterScanScopeStore?) -> [URL] {
        if let custom = scope?.scanRoots { return custom }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// The user's exclusions plus the fixed-path Apple Music / iTunes media
    /// folders, so the byte-reading scans never trip a media privacy prompt.
    private static func clutterExclusions(_ exclusions: ExclusionsStore?) -> [URL] {
        let user = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
        return user + DefaultUserFilesPathProvider().protectedMediaStores()
    }
}

/// Why a sub-scan couldn't look at what it was asked to.
enum MyClutterScanError: LocalizedError {
    case folderUnavailable(name: String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let name):
            let format = String(
                localized: "“%@” isn’t available. It may have been moved or renamed, or its drive may be disconnected. Choose another folder and scan again.",
                bundle: .module,
                comment: "My Clutter scan failure when the chosen folder can't be read; %@ is the folder name."
            )
            return String.localizedStringWithFormat(format, name)
        }
    }
}
