// AppInfo.swift
// Value type describing a single installed macOS application discovered by AppDiscovery and surfaced in the App Uninstaller list.

import Foundation

/// A single installed `.app` bundle plus the metadata the App Uninstaller
/// needs to display it and decide what to remove.
///
/// Bundle size is **not** part of this value — recursively summing every
/// regular file in every installed `.app` during the initial discovery
/// pass is expensive (multi-second on machines with many apps) and
/// pinning that work to launch makes the entire feature feel slow.
/// `AppUninstallerViewModel.bundleSize(for:)` computes the size lazily
/// when the user selects a row, in parallel with the associated-files
/// scan.
///
/// Icons are similarly resolved through a dedicated `@MainActor`
/// `AppIconCache` rather than carried on `AppInfo`, so the value type
/// stays cleanly `Sendable`.
///
/// `isAppStore` reflects the presence of `Contents/_MASReceipt/receipt`
/// inside the bundle — the canonical Mac App Store install marker —
/// and is reserved for future "show App Store apps separately" filters
/// and for App Updater (Prompt 20).
struct AppInfo: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String
    let version: String?
    let bundleURL: URL
    let isAppStore: Bool

    /// Spotlight's `kMDItemLastUsedDate` for the bundle, resolved during the
    /// discovery pass. Unlike bundle size, this is a single cheap index read,
    /// so it rides along on discovery and the App Uninstaller list can show and
    /// sort by last-opened the moment rows appear — no deferred second pass.
    /// `nil` means Spotlight has no usage record for the app.
    let lastUsedDate: Date?

    /// `id` keys off the bundle URL path so SwiftUI lists stay stable across
    /// repeated discovery passes — bundleID is not unique (two copies of the
    /// same app under `/Applications` and `~/Applications` would collide).
    var id: String { bundleURL.path }

    init(
        name: String,
        bundleID: String,
        version: String?,
        bundleURL: URL,
        isAppStore: Bool,
        lastUsedDate: Date? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.bundleURL = bundleURL
        self.isAppStore = isAppStore
        self.lastUsedDate = lastUsedDate
    }
}
