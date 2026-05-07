// LargeOldFilesScanner.swift
// Walks the user-files roots via FileScanner, then filters and re-tags each ScannedFile as .largeFile (size > 50 MB) or .oldFile (not accessed in 6+ months); files matching neither are dropped.

import Foundation

/// Top-level entry point for the Large & Old Files feature. Composes a
/// `UserFilesPathProviding` (which knows where the user keeps their personal
/// files) with a `FileScanning` (which does the recursive walk) and post-
/// processes the output to keep only files matching at least one criterion.
///
/// Two-pass design — walk-then-classify — instead of teaching `FileScanner`
/// about size/age predicates: keeps `FileScanner` a generic walker, lets the
/// thresholds be injected per-test, and means the same `FileScanner` instance
/// can be shared with `SystemJunkScanner` without either one growing
/// feature-specific knobs.
struct LargeOldFilesScanner {

    /// Files larger than this byte count are tagged `.largeFile`. 50 MB is
    /// the threshold called for in plan.md — high enough that it surfaces
    /// genuine forgotten media, low enough that it catches multi-megabyte
    /// installer disk images.
    static let sizeThresholdBytes: Int64 = 50 * 1024 * 1024

    /// Files whose `lastAccessDate` is more than 6 months in the past are
    /// tagged `.oldFile`. Expressed in seconds (`60 * 60 * 24 * 30 * 6`) so
    /// the constant is unit-clear at the call site.
    static let ageThresholdSeconds: TimeInterval = 60 * 60 * 24 * 30 * 6

    private let fileScanner: FileScanning
    private let pathProvider: UserFilesPathProviding
    private let now: () -> Date

    init(
        fileScanner: FileScanning = FileScanner(),
        pathProvider: UserFilesPathProviding = DefaultUserFilesPathProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileScanner = fileScanner
        self.pathProvider = pathProvider
        self.now = now
    }

    /// Runs the scan and returns the matching files. `excluding` is forwarded
    /// straight to the underlying `FileScanning` — the path-component-aware
    /// match semantics covered in `FileScannerTests` apply unchanged.
    ///
    /// Walks every root with a placeholder `.largeFile` category tag (the
    /// `ScanRoot` API requires one), then re-tags each file based on the
    /// per-file size and age check. The tiebreak when both apply is
    /// `.largeFile` — see `classify(_:cutoff:)`.
    func scan(excluding: [URL]) async throws -> [ScannedFile] {
        let roots = pathProvider.roots().map {
            // The placeholder category never reaches the caller — every file
            // is re-tagged below — so the value picked here is irrelevant.
            // We pass `.largeFile` for readability rather than introducing a
            // synthetic "unclassified" case to the public `ScanCategory` enum.
            ScanRoot(url: $0, category: .largeFile)
        }
        let everything = try await fileScanner.scan(roots: roots, excluding: excluding)
        let cutoff = now().addingTimeInterval(-Self.ageThresholdSeconds)
        return everything.compactMap { Self.classify($0, cutoff: cutoff) }
    }

    /// Returns the input file with its category re-tagged when it qualifies,
    /// or `nil` when neither criterion matches.
    ///
    /// **Tiebreak**: when a file is both large *and* old, we report it as
    /// `.largeFile`. Size is a deterministic file-system property; access
    /// dates can be unreliable on `noatime`-mounted volumes or after a
    /// restore. Reporting the more reliable signal first matches what users
    /// expect from "show me the biggest forgotten files" — they look at size
    /// before they look at age.
    ///
    /// Files with `lastAccessDate == nil` cannot be classified by age (per
    /// the `ScannedFile` doc comment, `nil` means "unknown — don't classify
    /// by age"), so they only enter the result set if they pass the size
    /// threshold. This avoids a stale-volume backup folder showing every
    /// 4-byte file as "ancient" just because its access date is missing.
    private static func classify(_ file: ScannedFile, cutoff: Date) -> ScannedFile? {
        let isLarge = file.size > sizeThresholdBytes
        let isOld: Bool = {
            guard let lastAccess = file.lastAccessDate else { return false }
            return lastAccess < cutoff
        }()
        guard isLarge || isOld else { return nil }
        return ScannedFile(
            url: file.url,
            size: file.size,
            lastAccessDate: file.lastAccessDate,
            lastModifiedDate: file.lastModifiedDate,
            category: isLarge ? .largeFile : .oldFile
        )
    }
}
