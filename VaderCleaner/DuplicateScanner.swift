// DuplicateScanner.swift
// Finds byte-identical files under ~/Downloads by bucketing on size, pre-filtering size collisions with a cheap prefix hash, then confirming with a streamed SHA-256 content hash, returning groups of duplicates.

import Foundation
import CryptoKit

/// Top-level entry point for the My Clutter (duplicate files) feature, matching
/// CleanMyMac's Smart Care, which surfaces duplicate files in Downloads. Reuses
/// `FileScanning` to walk the folder, buckets candidates by size (cheap), then
/// content-hashes only the size collisions with a streamed SHA-256 to confirm
/// true byte-for-byte duplicates.
struct DuplicateScanner {

    /// Bytes covered by the cheap first-pass hash tier. Files whose first
    /// `prefixHashByteLimit` bytes differ cannot be identical, so only prefix
    /// collisions pay a full-content read — the expensive step when a size
    /// bucket holds large files that diverge early. Internal so tests can
    /// build fixtures on either side of the boundary.
    static let prefixHashByteLimit = 64 * 1024

    /// Most content hashes in flight at once. Hashing is I/O-bound; a small
    /// bound overlaps reads across files without saturating the disk or
    /// holding more cooperative-pool threads than the work needs.
    private static let maxConcurrentHashes = 4

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
        // a slow on-demand download. Confirmation runs in two tiers: a cheap
        // prefix hash first (files diverging in their first bytes never pay a
        // full read), then a full-content hash over the surviving prefix
        // collisions.
        var groups: [DuplicateGroup] = []
        for (size, candidates) in bySize where candidates.count > 1 {
            try Task.checkCancellation()
            let local = candidates.filter { CloudFileAvailability.isLocallyAvailable($0.url) }
            guard local.count > 1 else { continue }

            let byPrefix = try await Self.groupedByContentHash(local, readingUpTo: Self.prefixHashByteLimit)
            for prefixMatches in byPrefix.values where prefixMatches.count > 1 {
                // A file no longer than the prefix tier is fully covered by
                // it — the prefix hash *is* the content hash, so these files
                // are already confirmed identical without a second read.
                if size <= Int64(Self.prefixHashByteLimit) {
                    groups.append(DuplicateGroup(files: Self.sortedKeepingOriginalFirst(prefixMatches)))
                    continue
                }
                let byHash = try await Self.groupedByContentHash(prefixMatches, readingUpTo: nil)
                for (_, identical) in byHash where identical.count > 1 {
                    groups.append(DuplicateGroup(files: Self.sortedKeepingOriginalFirst(identical)))
                }
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

    /// Buckets `files` by their content hash, reading at most `byteLimit`
    /// bytes per file (`nil` hashes the whole file). Hashes run with bounded
    /// concurrency (`maxConcurrentHashes`) so a big size bucket overlaps its
    /// file reads instead of paying them serially. Unreadable files are
    /// dropped, matching the single-hash behaviour.
    private static func groupedByContentHash(
        _ files: [ScannedFile],
        readingUpTo byteLimit: Int?
    ) async throws -> [String: [ScannedFile]] {
        let hashes = try await withThrowingTaskGroup(of: (Int, String?).self) { group -> [String?] in
            var results = [String?](repeating: nil, count: files.count)
            var nextIndex = 0
            func addTaskIfNeeded() {
                guard nextIndex < files.count else { return }
                let index = nextIndex
                let url = files[index].url
                nextIndex += 1
                group.addTask { (index, Self.sha256Hex(of: url, readingUpTo: byteLimit)) }
            }
            for _ in 0..<maxConcurrentHashes { addTaskIfNeeded() }
            while let (index, hash) = try await group.next() {
                results[index] = hash
                try Task.checkCancellation()
                addTaskIfNeeded()
            }
            return results
        }
        var byHash: [String: [ScannedFile]] = [:]
        for (file, hash) in zip(files, hashes) {
            guard let hash else { continue }
            byHash[hash, default: []].append(file)
        }
        return byHash
    }

    /// Streams the file through SHA-256 in 1 MB chunks so a large file never
    /// loads into memory at once. `readingUpTo` caps the bytes hashed (the
    /// prefix tier); `nil` hashes the whole file. Returns `nil` if the file
    /// can't be read, so an unreadable candidate is simply dropped rather than
    /// failing the scan.
    private static func sha256Hex(of url: URL, readingUpTo byteLimit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        var remaining = byteLimit ?? Int.max
        while remaining > 0 {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
