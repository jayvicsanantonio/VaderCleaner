// MyClutterManagerModel.swift
// Pure classification and grouping helpers for the My Clutter Manager review screen — the four categories, large/old file kind and size facets, and download-source grouping — kept free of SwiftUI so they can be unit-tested.

import Foundation

/// The four left-pane categories of the My Clutter Manager.
public enum MyClutterCategory: String, CaseIterable, Identifiable, Sendable {
    case largeOld
    case duplicates
    case similar
    case downloads

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .largeOld: return String(localized: "Large & Old Files", bundle: .module, comment: "My Clutter Manager category.")
        case .duplicates: return String(localized: "Duplicates", bundle: .module, comment: "My Clutter Manager category.")
        case .similar: return String(localized: "Similar Images", bundle: .module, comment: "My Clutter Manager category.")
        case .downloads: return String(localized: "Downloads", bundle: .module, comment: "My Clutter Manager category.")
        }
    }

    /// One-line explanation shown atop the middle pane.
    public var blurb: String {
        switch self {
        case .largeOld:
            return String(
                localized: "These files are large and likely unneeded — you haven't opened them in a while.",
                bundle: .module,
                comment: "My Clutter Manager Large & Old description."
            )
        case .duplicates:
            return String(
                localized: "Identical copies stored in different places. They may be wasting a lot of space.",
                bundle: .module,
                comment: "My Clutter Manager Duplicates description."
            )
        case .similar:
            return String(
                localized: "Shots that are nearly identical to the eye — keep the best one and remove the rest.",
                bundle: .module,
                comment: "My Clutter Manager Similar Images description."
            )
        case .downloads:
            return String(
                localized: "Downloads fill up with one-time-use files. Clear them out now and then to save space.",
                bundle: .module,
                comment: "My Clutter Manager Downloads description."
            )
        }
    }
}

/// Broad file kind used by the Large & Old facet list ("By Kind").
public enum MyClutterFileKind: String, CaseIterable, Sendable {
    case archives
    case videos
    case other

    public var title: String {
        switch self {
        case .archives: return String(localized: "Archives", bundle: .module, comment: "Large & Old kind facet.")
        case .videos: return String(localized: "Videos", bundle: .module, comment: "Large & Old kind facet.")
        case .other: return String(localized: "Other", bundle: .module, comment: "Large & Old kind facet.")
        }
    }

    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "gz", "bz2", "tar", "tgz", "tbz", "dmg", "pkg",
        "iso", "xip", "cpgz", "sit", "sitx", "war", "jar",
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg",
        "mpeg", "m2ts", "ts", "3gp", "mts",
    ]

    public static func of(_ url: URL) -> MyClutterFileKind {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return .archives }
        if videoExtensions.contains(ext) { return .videos }
        return .other
    }
}

/// Coarse size bucket used by the Large & Old facet list ("By Size").
public enum MyClutterSizeBucket: String, CaseIterable, Sendable {
    case huge
    case average
    case small

    public var title: String {
        switch self {
        case .huge: return String(localized: "Huge", bundle: .module, comment: "Large & Old size facet.")
        case .average: return String(localized: "Average", bundle: .module, comment: "Large & Old size facet.")
        case .small: return String(localized: "Small", bundle: .module, comment: "Large & Old size facet.")
        }
    }

    /// 1000-based thresholds, matching the file-style byte formatting used
    /// throughout the manager: huge ≥ 5 GB, average 1–5 GB, small < 1 GB.
    public static func of(_ size: Int64) -> MyClutterSizeBucket {
        if size >= 5_000_000_000 { return .huge }
        if size >= 1_000_000_000 { return .average }
        return .small
    }
}

/// The active facet shown in the Large & Old right pane.
public enum MyClutterLargeOldFacet: Hashable {
    case all
    case selected
    case kind(MyClutterFileKind)
    case size(MyClutterSizeBucket)
}

public enum MyClutterManagerModel {

    /// Files matching a Large & Old facet, drawn from the full result set and
    /// the current selection.
    static func files(
        for facet: MyClutterLargeOldFacet,
        in all: [ScannedFile],
        isSelected: (URL) -> Bool
    ) -> [ScannedFile] {
        switch facet {
        case .all:
            return all
        case .selected:
            return all.filter { isSelected($0.url) }
        case .kind(let kind):
            return all.filter { MyClutterFileKind.of($0.url) == kind }
        case .size(let bucket):
            return all.filter { MyClutterSizeBucket.of($0.size) == bucket }
        }
    }

    /// The rows the manager's right pane actually renders: the search filter
    /// (case-insensitive, on the file name), an optional name sort, and a cap
    /// on the rendered row count. Size-sorted lists arrive pre-sorted from the
    /// facet cache, so `sortByName == false` passes the input order through.
    /// Pure and `Sendable`-friendly so the view can recompute it off the main
    /// actor only when an input changes — never per render.
    public static func display(
        _ files: [ScannedFile],
        search: String,
        sortByName: Bool,
        limit: Int
    ) -> [ScannedFile] {
        var result = files
        if !search.isEmpty {
            result = result.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) }
        }
        if sortByName {
            result = result.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
        }
        return Array(result.prefix(limit))
    }

    /// Downloads grouped by their source app, ordered by total bytes (largest
    /// first). Files with no recorded source fall into an "Other" bucket.
    public static func downloadsBySource(_ items: [DownloadItem]) -> [MyClutterDownloadGroup] {
        var bySource: [String: [DownloadItem]] = [:]
        for item in items {
            let key = item.sourceApp ?? String(localized: "Other", bundle: .module, comment: "Downloads bucket for files with no recorded source.")
            bySource[key, default: []].append(item)
        }
        return bySource
            .map {
                MyClutterDownloadGroup(
                    source: $0.key,
                    bundleID: $0.value.first?.sourceBundleID,
                    items: $0.value,
                    bytes: $0.value.reduce(Int64(0)) { $0 + $1.file.size }
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }
}

/// A download source (a browser/app) with its files and total bytes. A
/// `Sendable` value type so the manager can build the grouping off the main
/// actor and hand it back. `bundleID` resolves the source app's icon.
public struct MyClutterDownloadGroup: Identifiable, Sendable {
    public let source: String
    public let bundleID: String?
    public let items: [DownloadItem]
    public let bytes: Int64
    public var id: String { source }
}
