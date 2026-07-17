// UnusedApp.swift
// Value type pairing an installed app with the date it was last used, surfaced on the Applications dashboard's Unused card.

import Foundation

/// A single installed app that hasn't been opened in a long time. `id` keys off
/// the underlying `AppInfo.id` (the bundle path) so SwiftUI list identity stays
/// stable across scans and after rows are removed. Only apps with a *known*
/// last-used date older than the threshold are surfaced, so `lastUsedDate` is
/// always present.
struct UnusedApp: Identifiable, Hashable, Sendable {
    let app: AppInfo
    let lastUsedDate: Date

    /// The app bundle's on-disk size, summed by the scanner when the app is
    /// flagged so the dashboard's Unused card can show the total reclaimable
    /// space without a second, post-render disk walk. Measuring only the small
    /// flagged subset here — not every installed app at discovery — is the
    /// reason `AppInfo` itself deliberately omits size.
    let sizeBytes: Int64

    var id: String { app.id }
}
