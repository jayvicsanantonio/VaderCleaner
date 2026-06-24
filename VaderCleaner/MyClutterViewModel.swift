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
final class MyClutterViewModel {

    /// Discrete phases the section detail view binds to.
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case empty
        case failed(message: String)
    }

    /// The four scan sources, each async + throwing so production wraps the real
    /// scanners and tests supply in-memory results. The progress parameter
    /// receives that scanner's running walked-item count.
    typealias DuplicateScan = (@escaping @Sendable (Int) -> Void) async throws -> [DuplicateGroup]
    typealias SimilarScan = (@escaping @Sendable (Int) -> Void) async throws -> [SimilarImageGroup]
    typealias LargeOldScan = (@escaping @Sendable (Int) -> Void) async throws -> [ScannedFile]
    typealias DownloadsScan = (@escaping @Sendable (Int) -> Void) async throws -> [DownloadItem]
    /// Deletion sink. Returns the URLs actually moved to the Trash; survivors
    /// stay in the dashboard.
    typealias Deleter = ([URL]) async -> Set<URL>

    private(set) var phase: Phase = .idle
    private(set) var scannedItemCount = 0

    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var similarGroups: [SimilarImageGroup] = []
    private(set) var largeOldFiles: [ScannedFile] = []
    private(set) var downloads: [DownloadItem] = []

    /// Unified deletion selection across every category, keyed by URL.
    private(set) var selectedURLs: Set<URL> = []
    private(set) var totalSelectedSize: Int64 = 0

    /// Bumped whenever the result *set* changes (scan completes, files
    /// trashed) — never on a selection toggle. The manager keys its off-main
    /// cache rebuild to this so it recomputes facets/groups only when the data
    /// actually changes, not on every checkbox click.
    private(set) var resultsVersion = 0

    /// Size of every reviewable file, so selection totals never re-walk the
    /// result arrays. Rebuilt when a scan completes.
    @ObservationIgnored private var sizeByURL: [URL: Int64] = [:]

    @ObservationIgnored private let duplicateScan: DuplicateScan
    @ObservationIgnored private let similarScan: SimilarScan
    @ObservationIgnored private let largeOldScan: LargeOldScan
    @ObservationIgnored private let downloadsScan: DownloadsScan
    @ObservationIgnored private let deleter: Deleter
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "MyClutterViewModel")

    init(
        duplicateScan: @escaping DuplicateScan,
        similarScan: @escaping SimilarScan,
        largeOldScan: @escaping LargeOldScan,
        downloadsScan: @escaping DownloadsScan,
        deleter: @escaping Deleter
    ) {
        self.duplicateScan = duplicateScan
        self.similarScan = similarScan
        self.largeOldScan = largeOldScan
        self.downloadsScan = downloadsScan
        self.deleter = deleter
    }

    // MARK: - Derived totals

    /// Redundant copies across the duplicate groups — the deletion candidates.
    var duplicateCopies: [ScannedFile] { duplicateGroups.flatMap { $0.redundantCopies } }
    /// Redundant near-duplicates across the similar-image groups.
    var similarCopies: [ScannedFile] { similarGroups.flatMap { $0.redundantCopies } }

    /// Total files the user can sort through — the count shown in the header.
    var totalFileCount: Int {
        duplicateCopies.count + similarCopies.count + largeOldFiles.count + downloads.count
    }

    var duplicateReclaimableBytes: Int64 { duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes } }
    var similarReclaimableBytes: Int64 { similarGroups.reduce(0) { $0 + $1.reclaimableBytes } }
    var largeOldBytes: Int64 { largeOldFiles.reduce(0) { $0 + $1.size } }
    var downloadsBytes: Int64 { downloads.reduce(0) { $0 + $1.file.size } }

    /// The browser/app that contributed the most download bytes, for the card
    /// title (e.g. "Google Chrome"), or `nil` for a generic label.
    var dominantDownloadSource: String? { DownloadsScanner.dominantSource(of: downloads) }

    /// The bundle id of the dominant download source, for its app icon on the
    /// dashboard card.
    var dominantDownloadBundleID: String? {
        guard let name = dominantDownloadSource else { return nil }
        return downloads.first { $0.sourceApp == name }?.sourceBundleID
    }

    // MARK: - Selection

    func isSelected(_ url: URL) -> Bool { selectedURLs.contains(url) }

    /// Toggle by path string — the id the review manager passes back.
    func toggleSelection(path: String) {
        toggleSelection(url: URL(fileURLWithPath: path))
    }

    func toggleSelection(url: URL) {
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
            totalSelectedSize -= sizeByURL[url] ?? 0
        } else {
            selectedURLs.insert(url)
            totalSelectedSize += sizeByURL[url] ?? 0
        }
    }

    /// Bulk select/clear a set of URLs (the review manager's "Select" menu).
    func setSelection(_ urls: [URL], selected: Bool) {
        for url in urls {
            let already = selectedURLs.contains(url)
            if selected, !already {
                selectedURLs.insert(url)
                totalSelectedSize += sizeByURL[url] ?? 0
            } else if !selected, already {
                selectedURLs.remove(url)
                totalSelectedSize -= sizeByURL[url] ?? 0
            }
        }
    }

    // MARK: - Scan

    /// Run all four scans concurrently and land in `.results`, `.empty`, or
    /// `.failed`. A single scanner throwing doesn't sink the others — its
    /// category is simply empty — so the dashboard always shows what succeeded.
    func scan() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        phase = .scanning
        scannedItemCount = 0
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
        applyResults(duplicates: d, similar: s, largeOld: l, downloads: w)
    }

    /// Reset to `.idle`, dropping cached results and selection. Wired to "Start
    /// Over" / the empty state's rescan.
    func scanAgain() {
        resetResults()
        scannedItemCount = 0
        phase = .idle
    }

    /// Move the current selection to the Trash and prune the survivors back into
    /// every category. A no-op when nothing is selected.
    func deleteSelected() async {
        guard !selectedURLs.isEmpty else { return }
        let actuallyDeleted = await deleter(Array(selectedURLs))
        guard !actuallyDeleted.isEmpty else { return }
        prune(deleted: actuallyDeleted)
    }

    /// Trash only the selected files that fall within `scope` — the category
    /// currently shown in the manager — leaving other categories' selections
    /// intact. Keeps the manager's footer total and its Remove action scoped to
    /// the category the user is reviewing.
    func deleteSelected(in scope: Set<URL>) async {
        let urls = Array(selectedURLs.intersection(scope))
        guard !urls.isEmpty else { return }
        let actuallyDeleted = await deleter(urls)
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
        sizeByURL = [:]
    }

    private func applyResults(
        duplicates: [DuplicateGroup],
        similar: [SimilarImageGroup],
        largeOld: [ScannedFile],
        downloads: [DownloadItem]
    ) {
        self.duplicateGroups = duplicates
        self.similarGroups = similar
        self.largeOldFiles = largeOld
        self.downloads = downloads

        rebuildSizeMap()
        // Nothing is selected by default — every Review / Review All Files opens
        // with an empty selection so the user opts each item in deliberately.
        selectedURLs = []
        totalSelectedSize = 0

        resultsVersion &+= 1
        phase = totalFileCount == 0 ? .empty : .results
    }

    private func rebuildSizeMap() {
        var map: [URL: Int64] = [:]
        for file in duplicateCopies { map[file.url] = file.size }
        for file in similarCopies { map[file.url] = file.size }
        for file in largeOldFiles { map[file.url] = file.size }
        for item in downloads { map[item.file.url] = item.file.size }
        sizeByURL = map
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

        rebuildSizeMap()
        selectedURLs.subtract(deleted)
        totalSelectedSize = selectedURLs.reduce(Int64(0)) { $0 + (sizeByURL[$1] ?? 0) }
        resultsVersion &+= 1
        phase = totalFileCount == 0 ? .empty : .results
    }

    /// Runs a throwing scan, logging and swallowing failures so one scanner
    /// can't sink the dashboard. Returns `nil` on failure (mapped to `[]` by
    /// the caller's `?? []`).
    private func runCatching<T>(_ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch is CancellationError {
            return nil
        } catch {
            log.error("My Clutter sub-scan failed: \(String(describing: error), privacy: .private(mask: .hash))")
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
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle: return .intro
        case .scanning: return .working
        case .results, .empty, .failed: return .results
        }
    }

    func beginScan() {
        guard phase != .scanning else { return }
        Task { await scan() }
    }
}

// MARK: - Production wiring

extension MyClutterViewModel {

    /// Build a view-model wired to the real scanners. The exclusions snapshot
    /// and the chosen scan folder are captured per scan, so a freshly-added
    /// exclusion or a just-picked folder takes effect on the next run.
    @MainActor
    static func live(
        exclusions: ExclusionsStore,
        scanScope: MyClutterScanScopeStore
    ) -> MyClutterViewModel {
        MyClutterViewModel(
            duplicateScan: { [weak exclusions, weak scanScope] onProgress in
                let ex = Self.clutterExclusions(exclusions)
                let roots = Self.clutterContentRoots(scope: scanScope)
                return try await DuplicateScanner(roots: roots).scan(excluding: ex, onProgress: onProgress)
            },
            similarScan: { [weak exclusions, weak scanScope] onProgress in
                let ex = Self.clutterExclusions(exclusions)
                let roots = Self.clutterContentRoots(scope: scanScope)
                return try await SimilarImageScanner(roots: roots).scan(excluding: ex, onProgress: onProgress)
            },
            largeOldScan: { [weak exclusions, weak scanScope] onProgress in
                let ex = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                let provider = DefaultUserFilesPathProvider(roots: scanScope?.scanRoots ?? nil)
                return try await LargeOldFilesScanner(pathProvider: provider).scan(excluding: ex, onProgress: onProgress)
            },
            downloadsScan: { [weak exclusions] onProgress in
                let ex = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                return try await DownloadsScanner().scan(excluding: ex, onProgress: onProgress)
            },
            deleter: { urls in await Self.trash(urls) }
        )
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

    /// Moves `urls` to the Trash via `NSWorkspace.recycle`, returning the set
    /// that was actually moved. Failures are skipped so a single locked file
    /// never aborts the batch.
    private nonisolated static func trash(_ urls: [URL]) async -> Set<URL> {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { newURLs, _ in
                let moved = Set(newURLs.keys)
                continuation.resume(returning: moved)
            }
        }
    }
}
