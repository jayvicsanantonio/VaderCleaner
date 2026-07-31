// UpdateInfo.swift
// Value type describing a single available update — installed vs. latest version, which channel surfaced it, and the URL to send the user to in order to install it.

import Foundation

/// Which channel surfaced an `UpdateInfo`. The App Updater UI renders a
/// badge per row using this; the view-model also routes the click target
/// (Mac App Store URL vs. Sparkle download URL) off this distinction.
enum UpdateSource: String, Hashable, Sendable {
    case appStore
    case sparkle
    /// Installed by a Homebrew cask and upgraded in place by `brew`.
    /// These rows carry no `updateURL` at all — see `UpdateInfo`.
    case homebrew
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
    /// Where to send the user to obtain this update, or `nil` when the
    /// update is applied in place rather than downloaded.
    ///
    /// Homebrew rows are the nil case, and deliberately so: handing a
    /// cask-owned app a direct download overwrites a Caskroom-tracked
    /// install. Modelling the absence removes the failure structurally,
    /// rather than relying on every call site to remember a guard.
    let updateURL: URL?
    /// The cask that installed this app, for `brew upgrade --cask`.
    /// Non-nil exactly when `source` is `.homebrew`.
    let homebrewToken: String?
    /// The appcast enclosure's Ed25519 signature, carried so an install
    /// can verify the download against the key on the installed bundle.
    /// Nil on channels that publish none, which blocks auto-install.
    let edSignature: String?
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
        updateURL: URL?,
        homebrewToken: String? = nil,
        edSignature: String? = nil,
        releaseNotes: String? = nil
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.source = source
        self.updateURL = updateURL
        self.homebrewToken = homebrewToken
        self.edSignature = edSignature
        self.releaseNotes = releaseNotes
    }
}
