// UnusedAppScanner.swift
// Flags installed apps that haven't been opened in a long time, reading each app's Spotlight kMDItemLastUsedDate and comparing it against a threshold (default 60 days).

import CoreServices
import Foundation
import os.log

/// Production scanner — reads each app's Spotlight last-used date and flags the
/// ones not opened within the threshold window (default 60 days).
///
/// Apps with **no** known last-used date are deliberately *not* flagged: a
/// missing `kMDItemLastUsedDate` means Spotlight has no usage record, not
/// necessarily that the app was never opened, so flagging it would risk a
/// false positive on an app the user actually relies on. The scanner biases
/// toward false negatives, only surfacing apps it can prove are stale.
struct DefaultUnusedAppScanner: Sendable {

    /// Apps not opened within this many days are considered unused. 60 days
    /// matches the reference design's default.
    static let defaultThresholdDays = 60

    private let thresholdSeconds: TimeInterval
    private let lastUsedDate: @Sendable (AppInfo) -> Date?
    private let bundleSize: @Sendable (AppInfo) -> Int64
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "UnusedAppScanner")

    /// - Parameters:
    ///   - thresholdDays: how stale an app must be to be flagged.
    ///   - lastUsedDate: resolves an app's last-used date, or `nil` when
    ///     unknown. Injected so tests drive classification with synthetic dates.
    ///   - bundleSize: resolves an app's on-disk size in bytes. Injected so
    ///     tests drive the size total without touching disk.
    ///   - now: the reference "now" for the staleness cutoff; injected so age
    ///     assertions don't depend on real time.
    init(
        thresholdDays: Int = DefaultUnusedAppScanner.defaultThresholdDays,
        lastUsedDate: @escaping @Sendable (AppInfo) -> Date? = DefaultUnusedAppScanner.spotlightLastUsedDate,
        bundleSize: @escaping @Sendable (AppInfo) -> Int64 = DefaultUnusedAppScanner.diskBundleSize,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.thresholdSeconds = TimeInterval(thresholdDays) * 24 * 60 * 60
        self.lastUsedDate = lastUsedDate
        self.bundleSize = bundleSize
        self.now = now
    }

    func scan(apps: [AppInfo]) async -> [UnusedApp] {
        let provider = lastUsedDate
        let sizeProvider = bundleSize
        let cutoff = now().addingTimeInterval(-thresholdSeconds)
        let log = log
        return await Task.detached(priority: .userInitiated) {
            let unused = apps.compactMap { app -> UnusedApp? in
                // Inclusive: an app last used exactly at the cutoff has not been
                // opened *within* the window, so it qualifies.
                guard let used = provider(app), used <= cutoff else { return nil }
                // Only the flagged apps are sized — a bounded subset — so the
                // walk stays off the discovery hot path.
                return UnusedApp(app: app, lastUsedDate: used, sizeBytes: sizeProvider(app))
            }
            // Oldest first — the longest-unused app is what the user most wants
            // to see.
            .sorted { $0.lastUsedDate < $1.lastUsedDate }
            log.debug("Unused-app scan flagged \(unused.count, privacy: .public) app(s)")
            return unused
        }.value
    }

    /// Default provider: Spotlight's `kMDItemLastUsedDate` for the app bundle,
    /// or `nil` when Spotlight has no record.
    static func spotlightLastUsedDate(_ app: AppInfo) -> Date? {
        guard let item = MDItemCreate(nil, app.bundleURL.path as CFString) else { return nil }
        guard let attribute = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return attribute as? Date
    }

    /// Default provider: the app bundle's recursive on-disk size in bytes,
    /// reusing the same walk the App Uninstaller uses for its per-row size.
    static func diskBundleSize(_ app: AppInfo) -> Int64 {
        DefaultAppDiscovery.bundleSize(at: app.bundleURL, fileManager: .default)
    }
}
