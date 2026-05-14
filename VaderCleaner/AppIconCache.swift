// AppIconCache.swift
// Per-bundle NSImage cache for the App Uninstaller list so rendering rows doesn't call NSWorkspace.shared.icon(forFile:) synchronously inside SwiftUI body.

import AppKit
import Combine

/// Caches `NSWorkspace.shared.icon(forFile:)` results keyed by the
/// `.app` bundle URL. The App Uninstaller list pre-loads icons on a
/// background queue when the discovery results land, then views read
/// synchronously from the cache during `body`. Bundles that haven't
/// been pre-loaded yet fall back to the generic application icon so
/// the row still renders something — the real icon swaps in once the
/// pre-load publishes its `revision` bump.
///
/// Cache is keyed by bundle URL path rather than file extension (the
/// strategy `FileIconCache` uses) because each `.app` has its own
/// asset-catalog icon — there's no shared "kind" key the way `.png`
/// or `.txt` share one.
@MainActor
final class AppIconCache: ObservableObject {
    /// Bumped after every batch of pre-loaded icons so SwiftUI views
    /// observing the cache re-render and pick up the freshly cached
    /// images.
    @Published private(set) var revision: Int = 0

    private var icons: [String: NSImage] = [:]
    private let placeholderIcon: NSImage
    private let loader: (URL) -> NSImage
    private let workQueue = DispatchQueue(label: "com.personal.VaderCleaner.app-icon-cache",
                                          qos: .userInitiated)

    /// `nonisolated` so SwiftUI views (which initialize at non-isolated
    /// scope) can construct the cache inline as a `@StateObject` default.
    /// All published mutation flows through `preloadIcons(for:)`, which
    /// remains main-actor isolated.
    nonisolated init(
        placeholderIcon: NSImage = NSWorkspace.shared.icon(for: .application),
        loader: @escaping (URL) -> NSImage = { url in
            NSWorkspace.shared.icon(forFile: url.path)
        }
    ) {
        self.placeholderIcon = placeholderIcon
        self.loader = loader
    }

    /// Returns the cached icon for `bundleURL`, or the generic
    /// application placeholder if the icon hasn't been pre-loaded yet.
    /// Safe to call from inside a SwiftUI `body`.
    func icon(for bundleURL: URL) -> NSImage {
        icons[bundleURL.path] ?? placeholderIcon
    }

    /// Pre-load icons for `urls` on a background queue. Idempotent —
    /// URLs already in the cache are skipped. Publishes a `revision`
    /// bump once new icons land so observing views re-render.
    func preloadIcons(for urls: [URL]) async {
        let missing = urls.filter { icons[$0.path] == nil }
        guard !missing.isEmpty else { return }

        let loader = self.loader
        let workQueue = self.workQueue
        let loaded: [(String, NSImage)] = await withCheckedContinuation { continuation in
            workQueue.async {
                let pairs = missing.map { ($0.path, loader($0)) }
                continuation.resume(returning: pairs)
            }
        }

        var added = 0
        for (path, image) in loaded where icons[path] == nil {
            icons[path] = image
            added += 1
        }
        if added > 0 {
            revision += 1
        }
    }
}
