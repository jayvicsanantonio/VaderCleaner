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
/// `id` is keyed off the bundle ID rather than the version pair so SwiftUI
/// lists stay stable across successive "Check for Updates" passes — the
/// version strings will flip from one check to the next, but the row
/// identity should not.
struct UpdateInfo: Identifiable, Hashable, Sendable {
    let appName: String
    let bundleID: String
    let installedVersion: String
    let latestVersion: String
    let source: UpdateSource
    let updateURL: URL

    var id: String { bundleID }
}
