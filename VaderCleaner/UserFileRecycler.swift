// UserFileRecycler.swift
// The one place the app moves user files to the Trash, so every caller gets the same empty-input guard, partial-failure reporting, and privacy annotations.

import AppKit
import os.log

/// Moves user files to the Trash on behalf of every section that offers a
/// "remove these files" action (Smart Scan, Applications, Space Lens, My
/// Clutter).
///
/// This exists because each of those sections previously carried its own copy
/// of the same `NSWorkspace.recycle` continuation wrapper, and the copies had
/// drifted: two guarded against an empty input and two did not, two logged the
/// failure and two discarded it entirely — so a file that failed to reach the
/// Trash in Space Lens or My Clutter left no trace at all.
///
/// `AppUninstallerViewModel.workspaceRecycle` is deliberately *not* routed
/// here. It returns the error to its caller instead of logging it, because an
/// app bundle that won't move to the Trash escalates to the privileged helper —
/// a different contract, not another copy of this one.
enum UserFileRecycler {

    private static let log = Logger(subsystem: "com.personal.VaderCleaner",
                                    category: "UserFileRecycler")

    /// Moves `urls` to the Trash and returns the subset that actually moved.
    ///
    /// `NSWorkspace.recycle` reports a *partial* result: the dictionary it
    /// hands back maps each original URL to its new location in the Trash, so a
    /// URL absent from the keys is one that did not move. Callers prune their
    /// models against the returned set rather than assuming the whole batch
    /// succeeded — a locked or permission-denied file has to stay on screen.
    ///
    /// A failure is logged rather than thrown for the same reason: a partial
    /// failure is not a failure of the operation, and the caller still needs
    /// the set that succeeded.
    ///
    /// - Parameter context: Which surface asked, so one log stream can be told
    ///   apart. `StaticString` because it must be a compile-time literal to be
    ///   safe to log `.public`.
    static func recycle(_ urls: [URL], context: StaticString) async -> Set<URL> {
        guard !urls.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { moved, error in
                if let error {
                    // `localizedDescription` is `.private` because Foundation
                    // embeds the offending filename in it verbatim — "“Tax
                    // Return.pdf” couldn't be removed because you don't have
                    // permission to access it." Logging it `.public` would put
                    // user filenames in the unified log even where the caller
                    // took care to mask the path it passed in. The counts are
                    // `.public`: they are the part worth reading at a glance.
                    log.error("""
                    \(context, privacy: .public): recycled \(moved.count, privacy: .public) of \
                    \(urls.count, privacy: .public) items: \(error.localizedDescription, privacy: .private)
                    """)
                }
                continuation.resume(returning: Set(moved.keys))
            }
        }
    }
}
