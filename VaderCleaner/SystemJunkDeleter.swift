// SystemJunkDeleter.swift
// Routes ScannedFile deletion between FileManager (user-domain paths) and the privileged XPC helper (system-domain paths) and reports the bytes actually freed.

import Foundation
import os.log

/// Deletes the files emitted by a System Junk scan, returning the total bytes
/// successfully freed. The split between `FileManager.removeItem` and the
/// privileged helper's `deleteFiles(_:reply:)` is decided per-file from the
/// path prefix — anything under `/Library`, `/private/var`, or `/Volumes/*/.Trashes`
/// goes to the helper because those locations are not writable in-process even
/// with Full Disk Access. Everything else (the user's `~/Library`, `~/.Trash`,
/// `~/Library/Mail Downloads`, `~/Library/Application Support/MobileSync/Backup`)
/// is removed in-process.
///
/// Errors on individual files are logged and skipped — a single locked log
/// file must never abort the whole clean. The returned `bytesFreed` reflects
/// only the files we actually removed, so the UI never claims a freed-space
/// total it did not deliver.
struct SystemJunkDeleter {

    /// Path prefixes that must be deleted via the privileged helper. Stored
    /// without trailing slashes so a `hasPrefix` check matches both the
    /// directory itself and any descendant.
    private static let helperOnlyPrefixes: [String] = [
        "/Library/",
        "/private/var/",
        "/System/",
        "/Volumes/"
    ]

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "SystemJunkDeleter")

    private let fileManager: FileManager
    private let helperProvider: () -> VaderCleanerHelperProtocol?

    init(
        fileManager: FileManager = .default,
        helperProvider: @escaping () -> VaderCleanerHelperProtocol? = SystemJunkDeleter.defaultHelperProvider
    ) {
        self.fileManager = fileManager
        self.helperProvider = helperProvider
    }

    /// Deletes every file in `files` and returns the sum of byte sizes for
    /// the ones that were successfully removed.
    func delete(_ files: [ScannedFile]) async throws -> Int64 {
        let (helperFiles, userFiles) = partition(files)

        var bytesFreed: Int64 = 0
        for file in userFiles {
            do {
                try fileManager.removeItem(at: file.url)
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

    /// Splits `files` into `(needsHelper, userDomain)` based on path prefix.
    private func partition(_ files: [ScannedFile]) -> ([ScannedFile], [ScannedFile]) {
        var helper: [ScannedFile] = []
        var user: [ScannedFile] = []
        for file in files {
            if Self.requiresHelper(path: file.url.path) {
                helper.append(file)
            } else {
                user.append(file)
            }
        }
        return (helper, user)
    }

    /// True when the path must go through the privileged helper. Public so
    /// `SystemJunkDeleterTests` can pin the routing without instantiating
    /// the deleter.
    static func requiresHelper(path: String) -> Bool {
        for prefix in helperOnlyPrefixes {
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Attempts a single batched helper call. The XPC interface uses the
    /// classic reply-block style so we bridge through
    /// `withCheckedContinuation`. On any error from the proxy we treat the
    /// whole batch as failed and return `0` — the helper has a best-effort
    /// contract (it deletes what it can and returns the first error), but
    /// because the protocol does not surface a per-path success vector, we
    /// do not credit byte counts in the failure case.
    private func deleteViaHelper(files: [ScannedFile]) async -> Int64 {
        let paths = files.map { $0.url.path }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        let error: Error? = await withCheckedContinuation { continuation in
            guard let helper = helperProvider() else {
                continuation.resume(returning: NSError(
                    domain: "com.personal.VaderCleaner.SystemJunkDeleter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Helper unavailable"]
                ))
                return
            }
            helper.deleteFiles(paths) { error in
                continuation.resume(returning: error)
            }
        }

        if let error {
            log.error("Helper deletion failed for \(paths.count, privacy: .public) paths: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        return totalBytes
    }

    /// Default helper provider — returns the proxy from
    /// `HelperConnectionManager.shared`. Logs and returns nil on connection
    /// errors (e.g. helper not registered in dev), letting the caller treat
    /// system-domain deletes as failed without crashing.
    static let defaultHelperProvider: () -> VaderCleanerHelperProtocol? = {
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SystemJunkDeleter.HelperProvider")
        return HelperConnectionManager.shared.helper { error in
            log.error("Helper connection error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
