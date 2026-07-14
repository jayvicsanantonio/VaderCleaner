// ScanFileFilter.swift
// Filters a scan's files to a selected subset off the main actor, so a Run/Clean tap over a million-item result never hashes URLs on the main thread.

import Foundation

/// Off-main filtering of a scan's files by a selection predicate.
///
/// A Run or Clean tap filters the full junk result (a million files on a busy
/// Mac) down to the user's selection. Doing that on the main actor hashes every
/// bridged `URL` on the main thread and beach-balls the tap — the same stall
/// class `ScanSelectionSeed` fixes at scan completion.
enum ScanFileFilter {

    /// The files matching `isSelected`, filtered off the main actor.
    ///
    /// The work runs off-main because this is a `nonisolated async` function:
    /// awaiting it from a `@MainActor` caller resumes on the cooperative pool,
    /// not the main actor (the same mechanism `ScanSelectionSeed`'s builders
    /// use). The `@Sendable` predicate is load-bearing — a non-`@Sendable`
    /// closure would inherit the caller's main-actor isolation and pull the
    /// filter back onto the main thread, reintroducing the freeze.
    nonisolated static func selected(
        from files: [ScannedFile],
        matching isSelected: @Sendable (ScannedFile) -> Bool
    ) async -> [ScannedFile] {
        files.filter(isSelected)
    }
}
