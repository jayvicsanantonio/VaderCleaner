// UpdateInfo.swift
// Value type describing a single available update — installed vs. latest version, which channel surfaced it, and the URL to send the user to in order to install it.

import Foundation

/// Which channel surfaced an `UpdateInfo`. The App Updater UI renders a
/// badge per row using this; the view-model also routes the click target
/// (Mac App Store URL vs. Sparkle download URL) off this distinction.
enum UpdateSource: String, Hashable, Sendable {
    case appStore
    case sparkle
}

/// A single update available for an installed app.
///
/// `id` keys off the installed bundle's path rather than the bundle ID or
/// the version pair. Versions flip between successive "Check for Updates"
/// passes, so the row identity must not depend on them — but the bundle
/// ID alone isn't unique either: the same app can be installed in two
/// locations (e.g. `/Applications` and `~/Applications`), which `AppInfo`
/// explicitly supports by keying *its* id off `bundleURL.path`. Mirroring
/// that here keeps each installed copy a distinct SwiftUI row instead of
/// colliding into one identity and dropping/reusing the wrong row.
struct UpdateInfo: Identifiable, Hashable, Sendable {
    let appName: String
    let bundleID: String
    let bundleURL: URL
    let installedVersion: String
    let latestVersion: String
    let source: UpdateSource
    let updateURL: URL
    /// What changed in `latestVersion`, as one plain-text line, or nil
    /// when the channel published none. "12.8 → 12.9" alone tells the
    /// user nothing about whether the update matters to them.
    let releaseNotes: String?

    var id: String { bundleURL.path }

    init(
        appName: String,
        bundleID: String,
        bundleURL: URL,
        installedVersion: String,
        latestVersion: String,
        source: UpdateSource,
        updateURL: URL,
        releaseNotes: String? = nil
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.source = source
        self.updateURL = updateURL
        self.releaseNotes = releaseNotes
    }
}
