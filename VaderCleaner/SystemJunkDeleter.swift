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
/// Errors on individual files are logged and skipped — a single locked log
/// file must never abort the whole clean. The returned `bytesFreed` reflects
/// only the files we actually removed, so the UI never claims a freed-space
/// total it did not deliver.
struct SystemJunkDeleter {

    /// Closure that yields a fresh helper proxy bound to the supplied
    /// per-call XPC error handler, or `nil` if the helper is unreachable.
    /// We accept the error handler at provider time (rather than letting
    /// `HelperConnectionManager` keep a single global one) so each
    /// `deleteViaHelper(...)` await can be resumed by whichever of the
    /// reply block or the connection-level error handler fires first.
    typealias HelperProvider = (@escaping (Error) -> Void) -> VaderCleanerHelperProtocol?

    /// Moves a single user-domain file to the Trash. Injectable so tests can
    /// redirect to a sandboxed directory instead of the real `~/.Trash`;
    /// production uses `FileManager.trashItem`.
    typealias TrashItem = (URL) throws -> Void

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

    private let fileManager: FileManager
    private let helperProvider: HelperProvider
    private let trashItem: TrashItem

    init(
        fileManager: FileManager = .default,
        helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider,
        trashItem: TrashItem? = nil
    ) {
        self.fileManager = fileManager
        self.helperProvider = helperProvider
        // `FileManager.trashItem` always targets the system Trash regardless of
        // the instance, so the trash destination is its own seam rather than a
        // property of the injected `fileManager`.
        self.trashItem = trashItem ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Deletes every file in `files` and returns the sum of byte sizes for
    /// the ones that were successfully removed.
    ///
    /// User-domain files are moved to the **Trash** (recoverable) rather than
    /// deleted outright, so a Clean can be undone from Finder. Two cases stay a
    /// permanent removal because the Trash doesn't apply: items already in a
    /// Trash (emptying the Trash Bins), and system/root files routed through the
    /// privileged helper (rebuildable caches/logs and the root-owned Document
    /// Versions store, which can't move to the user's Trash).
    func delete(_ files: [ScannedFile]) async throws -> Int64 {
        let (helperFiles, userFiles) = partition(files)

        var bytesFreed: Int64 = 0
        for file in userFiles {
            do {
                if Self.isInUserTrash(path: file.url.path) {
                    // Emptying the Trash is, by definition, permanent.
                    try fileManager.removeItem(at: file.url)
                } else {
                    // Recoverable: move to the Trash instead of deleting.
                    try trashItem(file.url)
                }
                bytesFreed += file.size
            } catch {
                log.debug("Skipping unremovable user file \(file.url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !helperFiles.isEmpty {
            let succeeded = await deleteViaHelper(files: helperFiles)
            bytesFreed += succeeded
        }

        return bytesFreed
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
    static func isInUserTrash(path: String) -> Bool {
        path.contains("/.Trash/")
    }

    /// Attempts a single batched helper call. The XPC interface uses the
    /// classic reply-block style so we bridge through `withCheckedContinuation`.
    ///
    /// `NSXPCConnection` may, in failure cases, fire the connection-level
    /// error handler **instead of** the per-call reply block — leaving an
    /// unresolved continuation forever and freezing the cleaning UI on the
    /// spinner. To prevent that, we install both: the helper proxy is built
    /// with a per-call error handler and the reply block is registered as
    /// usual. Whichever path resumes first wins, the other becomes a no-op
    /// thanks to `Resumer.resume(with:)`'s once-only guarantee.
    ///
    /// On any error from either path we treat the whole batch as failed and
    /// return `0` — the helper has a best-effort contract (it deletes what
    /// it can and returns the first error), but because the protocol does
    /// not surface a per-path success vector, we do not credit byte counts
    /// in the failure case.
    private func deleteViaHelper(files: [ScannedFile]) async -> Int64 {
        let paths = files.map { $0.url.path }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        let error: Error? = await withCheckedContinuation { continuation in
            let resumer = Resumer(continuation: continuation)
            let helper = helperProvider { connectionError in
                resumer.resume(with: connectionError)
            }
            guard let helper else {
                resumer.resume(with: HelperConnectionError.unavailable)
                return
            }
            helper.deleteFiles(paths) { replyError in
                resumer.resume(with: replyError)
            }
        }

        if let error {
            log.error("Helper deletion failed for \(paths.count, privacy: .public) paths: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        return totalBytes
    }

    /// Default helper provider — returns the proxy from
    /// `HelperConnectionManager.shared` bound to the per-call error handler.
    /// Logs the connection error in addition to forwarding it (so the failure
    /// is visible in Console even when the awaiting call has already
    /// resumed).
    static let defaultHelperProvider: HelperProvider = { errorHandler in
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SystemJunkDeleter.HelperProvider")
        return HelperConnectionManager.shared.helper { error in
            log.error("Helper connection error: \(error.localizedDescription, privacy: .public)")
            errorHandler(error)
        }
    }
}

// MARK: - Once-only continuation resume

/// Wraps a `CheckedContinuation` so that exactly one of the multiple paths
/// that may complete it (XPC reply block, XPC error handler, "helper
/// unavailable" early return) actually resumes — subsequent attempts are
/// silently dropped. `CheckedContinuation` traps on a second resume, which
/// would otherwise crash the app the first time the helper connection
/// dropped mid-call.
///
/// A class because it must be referenced by multiple closures and mutated
/// from whichever fires first. The `NSLock` covers the "two callbacks land
/// on different threads at the same time" race.
private final class Resumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?

    init(continuation: CheckedContinuation<Error?, Never>) {
        self.continuation = continuation
    }

    func resume(with error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: error)
    }
}
