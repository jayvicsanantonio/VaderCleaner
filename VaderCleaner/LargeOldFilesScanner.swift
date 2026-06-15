// LargeOldFilesScanner.swift
// Walks the user-files roots via FileScanner batches, then filters and re-tags each ScannedFile as .largeFile (size > 50 MB) or .oldFile (not accessed in 6+ months); files matching neither are dropped.

import Foundation

/// Top-level entry point for the Large & Old Files feature. Composes a
/// `UserFilesPathProviding` (which knows where the user keeps their personal
/// files) with a `FileScanning` (which does the recursive walk) and post-
/// processes each emitted batch to keep only files matching at least one
/// criterion. `FileScanner` stays a generic walker, while this scanner can
/// stream matched files to callers that want incremental UI updates.
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

    /// Extensions for app-managed virtual disks and VM/container volumes. The
    /// scan skips these for two reasons: deleting one destroys the owning app's
    /// data (Docker images, virtual machines, disk-image backups), so it is not
    /// "reclaimable junk"; and they are sparse, so their logical size wildly
    /// overstates what they actually occupy on disk (a 2 TB `Docker.raw` may
    /// use a fraction of that). `.raw` is handled separately because a bare
    /// `.raw` can also be a camera photo.
    static let virtualDiskExtensions: Set<String> = [
        "utm", "vmdk", "qcow2", "qcow", "vdi", "vhd", "vhdx", "hds",
        "pvm", "vbox", "vmwarevm", "sparsebundle", "sparseimage"
    ]

    /// Path fragments that mark a container/VM data store. Used to gate the
    /// ambiguous `.raw` extension: a Docker VM volume lives at
    /// `…/com.docker.docker/Data/vms/0/data/Docker.raw`, whereas a camera
    /// `.raw` photo lives under Pictures and must not be hidden.
    private static let virtualDiskPathMarkers: [String] = [
        "/vms/", "com.docker", "/.docker/", "colima", "orbstack", "/lima/", "podman"
    ]

    /// Whether `url` is an app-managed virtual disk image the scan should skip.
    /// Unambiguous VM/disk-image extensions always match; the catch-all `.raw`
    /// matches only inside a known container/VM store so genuine camera RAW
    /// photos are still surfaced.
    static func isVirtualDiskImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if virtualDiskExtensions.contains(ext) { return true }
        guard ext == "raw" else { return false }
        let path = url.path.lowercased()
        return virtualDiskPathMarkers.contains { path.contains($0) }
    }

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

    func scan(
        excluding: [URL],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [ScannedFile] {
        var matches: [ScannedFile] = []
        try await scan(
            excluding: excluding,
            batchSize: FileScanner.defaultBatchSize,
            onProgress: onProgress
        ) { matchedBatch in
            matches.append(contentsOf: matchedBatch)
        }
        return matches
    }

    /// Runs the scan and emits matching files in batches. Caller-provided
    /// `excluding` paths are combined with `pathProvider.protectedMediaStores()`
    /// before being forwarded to the underlying `FileScanning`; the
    /// path-component-aware match semantics covered in `FileScannerTests`
    /// apply unchanged.
    ///
    /// Walks every root with a placeholder `.largeFile` category tag (the
    /// `ScanRoot` API requires one), then re-tags each file based on the
    /// per-file size and age check. The tiebreak when both apply is
    /// `.largeFile` — see `classify(_:cutoff:)`.
    func scan(
        excluding: [URL],
        batchSize: Int = FileScanner.defaultBatchSize,
        onProgress: (@Sendable (Int) -> Void)? = nil,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        let roots = pathProvider.roots().map {
            // The placeholder category never reaches the caller — every file
            // is re-tagged below — so the value picked here is irrelevant.
            // We pass `.largeFile` for readability rather than introducing a
            // synthetic "unclassified" case to the public `ScanCategory` enum.
            ScanRoot(url: $0, category: .largeFile)
        }
        // Keep the walk out of TCC-protected media stores so it never trips a
        // macOS Photos/Music privacy prompt. Apple Music's media folder is a
        // plainly-named directory at a fixed path, so it is excluded by path;
        // photo-library bundles can live anywhere, so `skipsProtectedMediaStores`
        // has `FileScanner` recognise and skip them by name mid-walk.
        let allExclusions = excluding + pathProvider.protectedMediaStores()
        let cutoff = now().addingTimeInterval(-Self.ageThresholdSeconds)
        try await fileScanner.scan(
            roots: roots,
            excluding: allExclusions,
            options: FileScanOptions(packagesAsFiles: true, skipsProtectedMediaStores: true),
            batchSize: batchSize,
            onProgress: onProgress
        ) { scannedBatch in
            let matchedBatch = scannedBatch.compactMap { Self.classify($0, cutoff: cutoff) }
            guard !matchedBatch.isEmpty else { return }
            try Task.checkCancellation()
            try await onBatch(matchedBatch)
            try Task.checkCancellation()
        }
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
        // Skip app-managed virtual disks (Docker.raw, *.utm, *.sparsebundle, …)
        // before any size/age check: deleting them is destructive, and their
        // sparse logical size would otherwise dominate the results with a
        // phantom multi-terabyte entry.
        if isVirtualDiskImage(file.url) { return nil }
        let isLarge = file.size > sizeThresholdBytes
        let isOld: Bool = {
            guard let lastAccess = file.lastAccessDate else { return false }
            // Inclusive: a file accessed exactly at the 6-month cutoff is
            // already "not accessed within the past six months", so it
            // belongs in the old-files bucket. Strict `<` would leave a
            // one-second sliver where the boundary case is invisible to
            // the user — without inclusive comparison the result depends
            // on file-system timestamp resolution.
            return lastAccess <= cutoff
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
