// DocumentVersionsScanner.swift
// Enumerates the root-owned macOS Document Versions store through the privileged helper, returning ScannedFile records the in-process FileScanner can't read itself.

import Foundation
import os.log

/// Lists the regular files inside the Document Versions store
/// (`kDocumentVersionsStorePath`). That directory is owned by root and
/// execute-only, so the app can't enumerate it in-process even with Full Disk
/// Access — the privileged helper does it as root via
/// `scanDocumentVersions(reply:)` and hands back the paths and sizes here, which
/// we wrap as `.documentVersions` `ScannedFile`s for the Cleanup scan.
///
/// Any failure (helper unavailable, store missing, enumeration error) yields an
/// empty result so a Cleanup scan degrades gracefully — the Document Versions
/// card simply doesn't appear, rather than the whole scan failing.
struct DocumentVersionsScanner {

    /// Mirrors `SystemJunkDeleter.HelperProvider`: yields a helper proxy bound to
    /// the per-call XPC error handler, or `nil` when the helper is unreachable.
    typealias HelperProvider = (@escaping (Error) -> Void) -> VaderCleanerHelperProtocol?

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "DocumentVersionsScanner")
    private let helperProvider: HelperProvider

    init(helperProvider: @escaping HelperProvider = DocumentVersionsScanner.defaultHelperProvider) {
        self.helperProvider = helperProvider
    }

    /// Enumerates the store and returns one `.documentVersions` file per regular
    /// file the helper reported. Empty on any error.
    func scan() async -> [ScannedFile] {
        // Both the reply block and the connection-level error handler may fire;
        // the once-only resumer guarantees the continuation resumes exactly once
        // (a second `resume` would trap), mirroring `SystemJunkDeleter`.
        let payload: ([String], [NSNumber])? = await withCheckedContinuation { continuation in
            let resumer = OnceResumer(continuation: continuation)
            let helper = helperProvider { [log] connectionError in
                log.error("Document Versions scan failed: \(connectionError.localizedDescription, privacy: .public)")
                resumer.resume(returning: nil)
            }
            guard let helper else {
                resumer.resume(returning: nil)
                return
            }
            helper.scanDocumentVersions { [log] paths, sizes, replyError in
                if let replyError {
                    log.error("Document Versions scan failed: \(replyError.localizedDescription, privacy: .public)")
                    resumer.resume(returning: nil)
                } else {
                    resumer.resume(returning: (paths, sizes))
                }
            }
        }

        guard let (paths, sizes) = payload else { return [] }
        // Defend against a malformed reply where the parallel arrays disagree.
        let count = min(paths.count, sizes.count)
        return (0..<count).map { index in
            ScannedFile(
                url: URL(fileURLWithPath: paths[index]),
                size: sizes[index].int64Value,
                lastAccessDate: nil,
                lastModifiedDate: nil,
                category: .documentVersions
            )
        }
    }

    /// Default provider — the shared connection's proxy bound to the per-call
    /// error handler, matching `SystemJunkDeleter.defaultHelperProvider`.
    static let defaultHelperProvider: HelperProvider = { errorHandler in
        HelperConnectionManager.shared.helper(errorHandler: errorHandler)
    }
}

/// Resumes a `CheckedContinuation` exactly once across the multiple callbacks
/// that may complete an XPC call (reply block, connection error handler, early
/// "unavailable" return). A second `resume` traps, which would otherwise crash
/// the app the first time the helper connection dropped mid-call. A class so the
/// several closures share one mutable slot; the lock covers the cross-thread race.
private final class OnceResumer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
