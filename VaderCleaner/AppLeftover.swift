// AppLeftover.swift
// Value type describing the orphaned support files of an app that is no longer installed, grouped by bundle ID and surfaced on the Applications dashboard's Leftovers card.

import Foundation

/// All the leftover support files found for one uninstalled app's bundle ID,
/// aggregated across the scanned `~/Library` roots. `id` keys off the bundle ID
/// so SwiftUI list identity is stable across scans and after rows are removed.
struct LeftoverGroup: Identifiable, Hashable, Sendable {
    /// The reverse-DNS bundle ID these files belong to (e.g. `com.acme.App`).
    let bundleID: String
    /// A short human-facing label derived from the bundle ID (its last
    /// component, e.g. "App"), shown as the row title.
    let displayName: String
    /// Every leftover file/directory found for this bundle ID, across roots.
    let urls: [URL]
    /// Combined size of all `urls`.
    let totalBytes: Int64

    var id: String { bundleID }
}
