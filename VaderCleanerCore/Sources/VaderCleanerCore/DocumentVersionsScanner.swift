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
    typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?

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
        // `OnceResumer` guarantees the continuation resumes exactly once (a
        // second `resume` would trap). This selector replies with a payload
        // rather than an error, so it uses the resumer directly instead of
        // `HelperCall.perform` — the watchdog is armed the same way.
        let payload: ([String], [NSNumber])? = await withCheckedContinuation { continuation in
            let resumer = OnceResumer<([String], [NSNumber])?>(continuation: continuation)
            let helper = helperProvider { [log] connectionError in
                log.error("Document Versions scan failed: \(connectionError.localizedDescription, privacy: .private)")
                resumer.resume(returning: nil)
            }
            guard let helper else {
                resumer.resume(returning: nil)
                return
            }
            helper.scanDocumentVersions { [log] paths, sizes, replyError in
                if let replyError {
                    log.error("Document Versions scan failed: \(replyError.localizedDescription, privacy: .private)")
                    resumer.resume(returning: nil)
                } else {
                    resumer.resume(returning: (paths, sizes))
                }
            }
            // A wedged helper would otherwise leave the Smart Scan spinner up
            // forever; an empty result degrades to "nothing found" instead.
            resumer.armTimeout(HelperCall.defaultTimeout) { [log] in
                log.error("Document Versions scan timed out")
                return nil
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
