// SelfUpdaterDetector.swift
// Detects whether an installed app ships its own updater — Google Keystone or an embedded Squirrel.Mac — so apps the probe cannot query are reported as self-maintaining rather than as blind spots.

import Foundation

/// An updater an app carries itself. None of these expose a feed we can
/// query the way Sparkle's appcast or the App Store lookup can, so an app
/// carrying one is *unchecked but not neglected* — a distinction the
/// Updater's coverage report depends on. Lumping these in with apps that
/// have no updater at all produces a large, alarming, and mostly wrong
/// "not monitored" count.
enum SelfUpdater: String, Hashable, Sendable, CaseIterable {
    /// Google's Omaha-based updater, advertised by `KSUpdateURL`. Chrome
    /// and the other Google apps use it instead of Sparkle.
    case keystone
    /// Squirrel.Mac, embedded as a framework by most Electron apps.
    case squirrel
}

/// Classifies an app bundle by the updater it embeds. Reads only the
/// bundle itself — no network — so it is cheap enough to run for every
/// app the probe skips.
struct SelfUpdaterDetector: Sendable {

    /// `.default` is documented thread-safe and the fixture instances tests
    /// inject are touched only by their own test, so the isolation is opted
    /// out of here rather than the whole type giving up `Sendable`.
    nonisolated(unsafe) private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The updater `app` embeds, or `nil` when it has none we recognise.
    ///
    /// Keystone wins when both signals are present: `KSUpdateURL` names a
    /// concrete update service, which is the more specific claim than the
    /// mere presence of a framework.
    func selfUpdater(for app: AppInfo) -> SelfUpdater? {
        if hasKeystoneFeed(app) { return .keystone }
        if embedsSquirrel(app) { return .squirrel }
        return nil
    }

    /// A non-empty `KSUpdateURL` string. The empty-string guard mirrors
    /// `DefaultSparkleUpdateChecker.feedURL(for:)` — a blank key is a
    /// leftover, not a channel, and must not read as "this app is fine".
    private func hasKeystoneFeed(_ app: AppInfo) -> Bool {
        // `Bundle(url:)` transparently handles binary vs. XML plists and
        // uses the system bundle cache, rather than re-reading and
        // re-parsing Info.plist by hand. A missing or corrupt bundle
        // yields nil here, which is the correct "no updater" answer.
        guard let bundle = Bundle(url: app.bundleURL),
              let raw = bundle.object(forInfoDictionaryKey: "KSUpdateURL") as? String else {
            return false
        }
        return !raw.isEmpty
    }

    private func embedsSquirrel(_ app: AppInfo) -> Bool {
        let framework = app.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("Squirrel.framework", isDirectory: true)
        return fileManager.fileExists(atPath: framework.path)
    }
}
