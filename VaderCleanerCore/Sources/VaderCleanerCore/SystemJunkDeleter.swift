// SystemJunkDeleter.swift
// Routes ScannedFile deletion between FileManager (user-domain paths) and the privileged XPC helper (system-domain paths) and reports the bytes actually freed.

import Foundation
import os.log

/// Deletes the files emitted by a System Junk scan, returning the total bytes
/// successfully freed. The split between `FileManager.removeItem` and the
/// privileged helper's `deleteFiles(_:reply:)` is decided per-file from the
/// path. Routed through the helper:
///
///   - `/Library/...` and `/private/var/...` (system caches, logs, /var/folders)
///   - `/System/...` (kept routed even though SSV blocks it, so accidental
///     selections fail loudly via the helper rather than silently in-process)
///   - `/Applications/...` (system-installed `.app` bundles are usually owned
///     by `root:wheel` and not user-writable, so language-file deletion under
///     them would silently fail in-process)
///   - `/Volumes/<name>/.Trashes/<uid>/...` — per-user trash on mounted local
///     volumes; everything else under `/Volumes/...` is left in-process
///     because mounted external drives are typically user-writable.
///
/// Everything else (the user's `~/Library`, `~/.Trash`, `~/Library/Mail Downloads`,
/// `~/Library/Application Support/MobileSync/Backup`, and `~/Applications`)
/// is removed in-process.
///
/// Errors on individual files are logged and counted — a single locked log
/// file must never abort the whole clean. The `JunkRemovalReport` reflects only
/// the files that actually went, so the UI never claims a total it did not
/// deliver.
public struct SystemJunkDeleter: Sendable {

    /// Closure that yields a fresh helper proxy bound to the supplied
    /// per-call XPC error handler, or `nil` if the helper is unreachable.
    /// We accept the error handler at provider time (rather than letting
    /// `HelperConnectionManager` keep a single global one) so each
    /// `deleteViaHelper(...)` await can be resumed by whichever of the
    /// reply block or the connection-level error handler fires first.
    public typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?

    /// Moves a single user-domain file to the Trash. Injectable so tests can
    /// redirect to a sandboxed directory instead of the real `~/.Trash`;
    /// production uses `FileManager.trashItem`.
    typealias TrashItem = @Sendable (URL) throws -> Void

    /// Whether nothing exists at a path any more. Injectable so tests can state
    /// the outcome of a failed helper batch without real root-owned files.
    typealias PathIsGone = @Sendable (String) -> Bool

    /// Lists "gone" only on a definite answer: `lstat` also fails for a path the
    /// app isn't allowed to look at, and that says nothing about whether it went.
    static let defaultPathIsGone: PathIsGone = { path in
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    /// Plain prefix matches that mean "must go through the helper". Stored
    /// with trailing slashes so the check matches descendants but not paths
    /// that merely start with the same characters (`/Libraryfoo` ≠ `/Library/`).
    private static let helperOnlyPrefixes: [String] = [
        "/Library/",
        "/private/var/",
        "/System/",
        "/Applications/",
        // The Document Versions store at the data-volume root is owned by root;
        // saved revisions inside it can only be removed by the privileged helper.
        "/.DocumentRevisions-V100/"
    ]

    /// Substring that, when paired with `/Volumes/` rooting, marks per-volume
    /// `.Trashes/<uid>/...` paths as helper-only. Plain `/Volumes/X/foo` is
    /// left in-process because mounted external drives are typically writable
    /// by the user and don't need privilege escalation.
    private static let volumesTrashesNeedle = "/.Trashes/"

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "SystemJunkDeleter")

    /// Paths per privileged-helper XPC call. A large clean can route hundreds of
    /// thousands of paths through the helper; one giant `deleteFiles(_:)` message
    /// risks the XPC transport's size limits and makes the helper process the
    /// whole set as a single unit. Chunking bounds each message and lets a
    /// partial failure cost only its own batch.
    static let defaultHelperBatchSize = 10_000

    /// See `DefaultAppDiscovery.fileManager` — `.default` is documented
    /// thread-safe and test fixtures are single-threaded.
    nonisolated(unsafe) private let fileManager: FileManager
    /// The home whose `.Trash` counts as "already discarded". Injected so the
    /// permanent-removal branch can be exercised against a temp directory
    /// rather than the tester's real Trash.
    private let homeDirectory: URL
    private let helperProvider: HelperProvider
    private let trashItem: TrashItem
    private let helperBatchSize: Int
    private let pathIsGone: PathIsGone

    /// How many in-process removals pass between progress reports, so a clean of
    /// hundreds of thousands of files doesn't hop to the main actor for each one.
    private static let progressInterval = 256

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider,
        trashItem: TrashItem? = nil,
        helperBatchSize: Int = SystemJunkDeleter.defaultHelperBatchSize,
        pathIsGone: @escaping PathIsGone = SystemJunkDeleter.defaultPathIsGone
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.helperProvider = helperProvider
        self.helperBatchSize = max(1, helperBatchSize)
        self.pathIsGone = pathIsGone
        // `FileManager.trashItem` always targets the system Trash regardless of
        // the instance, so the trash destination is its own seam rather than a
        // property of the injected `fileManager` — and the default can name the
        // shared instance rather than capture the injected one, keeping this a
        // plain `@Sendable` closure.
        self.trashItem = trashItem ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Removes every file in `files` and reports what happened, stopping between
    /// items if the task is cancelled. `onProgress` receives the running count of
    /// items dealt with.
    ///
    /// User-domain files are moved to the **Trash** (recoverable) rather than
    /// deleted outright, so a Clean can be undone from Finder. Two cases stay a
    /// permanent removal because the Trash doesn't apply: items already in a
    /// Trash (emptying the Trash Bins), and system/root files routed through the
    /// privileged helper (rebuildable caches/logs and the root-owned Document
    /// Versions store, which can't move to the user's Trash).
    func remove(_ files: [ScannedFile], onProgress: (@Sendable (Int) -> Void)? = nil) async -> JunkRemovalReport {
        let (helperFiles, userFiles) = partition(files)

        var report = JunkRemovalReport()
        var processed = 0
        for file in userFiles {
            if Task.isCancelled {
                report.wasCancelled = true
                return report
            }
            do {
                if Self.isInUserTrash(path: file.url.path, homeDirectory: homeDirectory) {
                    // Emptying the Trash is, by definition, permanent.
                    try fileManager.removeItem(at: file.url)
                    report.bytesFreed += file.size
                } else {
                    // Recoverable: move to the Trash instead of deleting.
                    try trashItem(file.url)
                    report.bytesMovedToTrash += file.size
                }
                report.removedCount += 1
            } catch where Self.isNoSuchFile(error) {
                // Gone since the scan listed it: nothing freed, and nothing failed.
            } catch {
                report.failedCount += 1
                log.debug("Skipping unremovable user file \(file.url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
            processed += 1
            if processed.isMultiple(of: Self.progressInterval) { onProgress?(processed) }
        }
        onProgress?(processed)

        for chunk in helperFiles.chunked(into: helperBatchSize) where !chunk.isEmpty {
            if Task.isCancelled {
                report.wasCancelled = true
                return report
            }
            await deleteChunkViaHelper(files: chunk, into: &report)
            processed += chunk.count
            onProgress?(processed)
        }

        return report
    }

    /// Removes `files` and returns the bytes moved or removed, for callers that
    /// only need a total. Throws when every attempt failed, so a clean that did
    /// nothing can't read as a success with zero bytes.
    func delete(_ files: [ScannedFile]) async throws -> Int64 {
        let report = await remove(files)
        if report.removedNothing {
            throw JunkRemovalError.nothingRemoved(failedCount: report.failedCount)
        }
        return report.totalBytes
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
    }

    /// Splits `files` into `(needsHelper, userDomain)` based on the routing
    /// rule in `requiresHelper(path:)`.
    private func partition(_ files: [ScannedFile]) -> ([ScannedFile], [ScannedFile]) {
        files.reduce(into: ([ScannedFile](), [ScannedFile]())) { acc, file in
            if Self.requiresHelper(path: file.url.path) {
                acc.0.append(file)
            } else {
                acc.1.append(file)
            }
        }
    }

    /// True when `path` must go through the privileged helper. Public so
    /// `SystemJunkDeleterTests` can pin the routing rule without needing
    /// to instantiate the deleter or fake the helper.
    static func requiresHelper(path: String) -> Bool {
        if helperOnlyPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        if path.hasPrefix("/Volumes/") && path.contains(volumesTrashesNeedle) {
            return true
        }
        return false
    }

    /// True when `path` is inside the user's home Trash (`~/.Trash`). Such items
    /// are deleted permanently rather than moved to the Trash, since the whole
    /// point of cleaning the Trash Bins is to empty it. (Mounted-volume trashes
    /// match `/.Trashes/` and are routed through the helper instead.)
    ///
    /// Anchored at `homeDirectory` rather than matched as a `/.Trash/`
    /// substring: a folder the user happened to name `.Trash` — or another
    /// account's Trash — is ordinary user data, and the substring test sent it
    /// down the permanent-removal branch where nothing could be recovered.
    /// `~/.Trash` itself is not "inside" the Trash, so the directory can never
    /// be unlinked as a whole.
    static func isInUserTrash(
        path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        // Both sides go through `standardizedFileURL` only — it folds `.`/`..`
        // without the `/private` rewriting `NSString.standardizingPath` does,
        // which would make the two spellings disagree under a temp home.
        let trash = homeDirectory
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
            .path
        let prefix = trash.hasSuffix("/") ? trash : trash + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(prefix)
    }

    /// Attempts a single batched helper call and records the outcome in `report`.
    /// Batches are bounded (`helperBatchSize`) so a clean of hundreds of thousands
    /// of paths doesn't serialize into one oversized XPC message, and the caller
    /// continues with the rest whatever this one does. The XPC interface uses the
    /// classic reply-block style so we bridge through `withCheckedContinuation`.
    ///
    /// `NSXPCConnection` may, in failure cases, fire the connection-level
    /// error handler **instead of** the per-call reply block — leaving an
    /// unresolved continuation forever and freezing the cleaning UI on the
    /// spinner. `HelperCall.perform` installs both paths plus a watchdog and
    /// guarantees exactly one of them resolves the await.
    ///
    /// The helper is best-effort — it deletes what it can and returns the first
    /// error — and the protocol has no per-path result, so after an error each
    /// path is checked on disk. One protected file in a batch would otherwise cost
    /// the thousands around it their credit. A helper that was never reached has
    /// removed nothing, so that case needs no checking.
    private func deleteChunkViaHelper(files: [ScannedFile], into report: inout JunkRemovalReport) async {
        let paths = files.map { $0.url.path }

        let error = await HelperCall.perform(helperProvider: helperProvider) { helper, reply in
            helper.deleteFiles(paths, reply: reply)
        }

        guard let error else {
            report.bytesFreed += files.reduce(Int64(0)) { $0 + $1.size }
            report.removedCount += files.count
            return
        }
        log.error("Helper deletion failed for \(paths.count, privacy: .public) paths: \(error.localizedDescription, privacy: .private)")
        if case HelperConnectionError.unavailable = error {
            report.failedCount += files.count
            return
        }
        for file in files {
            if pathIsGone(file.url.path) {
                report.bytesFreed += file.size
                report.removedCount += 1
            } else {
                report.failedCount += 1
            }
        }
    }

    /// Default helper provider — returns the proxy from
    /// `HelperConnectionManager.shared` bound to the per-call error handler.
    /// Logs the connection error in addition to forwarding it (so the failure
    /// is visible in Console even when the awaiting call has already
    /// resumed).
    public static let defaultHelperProvider: HelperProvider = { errorHandler in
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SystemJunkDeleter.HelperProvider")
        return HelperConnectionManager.shared.helper { error in
            log.error("Helper connection error: \(error.localizedDescription, privacy: .private)")
            errorHandler(error)
        }
    }
}

private extension Array {
    /// Splits the array into consecutive sub-arrays of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
