// DuplicateScanner.swift
// Finds byte-identical files under ~/Downloads by bucketing on size then confirming with a streamed SHA-256 content hash, returning groups of duplicates.

import Foundation
import CryptoKit

/// Top-level entry point for the My Clutter (duplicate files) feature, matching
/// CleanMyMac's Smart Care, which surfaces duplicate files in Downloads. Reuses
/// `FileScanning` to walk the folder, buckets candidates by size (cheap), then
/// content-hashes only the size collisions with a streamed SHA-256 to confirm
/// true byte-for-byte duplicates.
struct DuplicateScanner {

    private let fileScanner: FileScanning
    private let roots: [URL]

    /// `downloadsURL` is injectable so tests can point at a temp directory.
    /// Production resolves the user's real Downloads folder by default.
    init(
        fileScanner: FileScanning = FileScanner(),
        downloadsURL: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ) {
        self.fileScanner = fileScanner
        self.roots = downloadsURL.map { [$0] } ?? []
    }

    /// Walk an explicit set of roots (e.g. the curated user-content folders the
    /// My Clutter section scans) rather than the user's Downloads folder.
    init(fileScanner: FileScanning = FileScanner(), roots: [URL]) {
        self.fileScanner = fileScanner
        self.roots = roots
    }

    /// Walks Downloads and returns the duplicate groups, ordered by reclaimable
    /// bytes (largest first). Honors `excluding` like the other feature scanners.
    /// Zero-byte files and unreadable files are skipped.
    func scan(
        excluding: [URL],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        guard !roots.isEmpty else { return [] }

        // Collect every non-empty file once. The placeholder category is unused
        // — duplicates don't carry a `ScanCategory` meaning — so any value works.
        var bySize: [Int64: [ScannedFile]] = [:]
        try await fileScanner.scan(
            roots: roots.map { ScanRoot(url: $0, category: .largeFile) },
            excluding: excluding,
            options: FileScanOptions(packagesAsFiles: true, skipsProtectedMediaStores: true),
            batchSize: FileScanner.defaultBatchSize,
            onProgress: onProgress
        ) { batch in
            for file in batch where file.size > 0 {
                bySize[file.size, default: []].append(file)
            }
            try Task.checkCancellation()
        }

        // Only size collisions can be duplicates — hash just those to confirm.
        // iCloud placeholders are skipped so confirming a duplicate never forces
        // a slow on-demand download.
        var groups: [DuplicateGroup] = []
        for (_, candidates) in bySize where candidates.count > 1 {
            try Task.checkCancellation()
            var byHash: [String: [ScannedFile]] = [:]
            for file in candidates where CloudFileAvailability.isLocallyAvailable(file.url) {
                guard let hash = Self.sha256Hex(of: file.url) else { continue }
                byHash[hash, default: []].append(file)
            }
            for (_, identical) in byHash where identical.count > 1 {
                groups.append(DuplicateGroup(files: Self.sortedKeepingOriginalFirst(identical)))
            }
        }

        // Largest payoff first.
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Orders identical files so the most canonical one (shortest path, then
    /// lexical) is first and is kept; the rest become the redundant copies.
    private static func sortedKeepingOriginalFirst(_ files: [ScannedFile]) -> [ScannedFile] {
        files.sorted { lhs, rhs in
            let lc = lhs.url.pathComponents.count
            let rc = rhs.url.pathComponents.count
            if lc != rc { return lc < rc }
            return lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path) == .orderedAscending
        }
    }

    /// Streams the file through SHA-256 in 1 MB chunks so a large file never
    /// loads into memory at once. Returns `nil` if the file can't be read, so an
    /// unreadable candidate is simply dropped rather than failing the scan.
    private static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
