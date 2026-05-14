// AppInfo.swift
// Value type describing a single installed macOS application discovered by AppDiscovery and surfaced in the App Uninstaller list.

import Foundation

/// A single installed `.app` bundle plus the metadata the App Uninstaller
/// needs to display it and decide what to remove.
///
/// `bundleSizeBytes` is computed lazily by `AppDiscovery` (size of the
/// `.app` directory tree); a value of `0` is acceptable when sizing
/// failed — the row still renders, just with no size label. `iconPath`
/// is intentionally a `URL?` rather than an `NSImage` so the value type
/// stays cleanly `Sendable`; the view layer resolves the icon via
/// `NSWorkspace.shared.icon(forFile:)` at render time so it picks up
/// the asset-catalog (`.car`) icons that modern apps use without us
/// having to parse `CFBundleIconFile` ourselves.
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
    let bundleSizeBytes: Int64
    let isAppStore: Bool

    /// `id` keys off the bundle URL path so SwiftUI lists stay stable across
    /// repeated discovery passes — bundleID is not unique (two copies of the
    /// same app under `/Applications` and `~/Applications` would collide).
    var id: String { bundleURL.path }
}
