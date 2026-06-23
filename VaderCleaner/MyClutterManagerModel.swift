// MyClutterManagerModel.swift
// Pure classification and grouping helpers for the My Clutter Manager review screen — the four categories, large/old file kind and size facets, and download-source grouping — kept free of SwiftUI so they can be unit-tested.

import Foundation

/// The four left-pane categories of the My Clutter Manager.
enum MyClutterCategory: String, CaseIterable, Identifiable {
    case largeOld
    case duplicates
    case similar
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largeOld: return String(localized: "Large & Old Files", comment: "My Clutter Manager category.")
        case .duplicates: return String(localized: "Duplicates", comment: "My Clutter Manager category.")
        case .similar: return String(localized: "Similar Images", comment: "My Clutter Manager category.")
        case .downloads: return String(localized: "Downloads", comment: "My Clutter Manager category.")
        }
    }

    /// One-line explanation shown atop the middle pane.
    var blurb: String {
        switch self {
        case .largeOld:
            return String(
                localized: "These files are large and likely unneeded — you haven't opened them in a while.",
                comment: "My Clutter Manager Large & Old description."
            )
        case .duplicates:
            return String(
                localized: "Identical copies stored in different places. They may be wasting a lot of space.",
                comment: "My Clutter Manager Duplicates description."
            )
        case .similar:
            return String(
                localized: "Shots that are nearly identical to the eye — keep the best one and remove the rest.",
                comment: "My Clutter Manager Similar Images description."
            )
        case .downloads:
            return String(
                localized: "Downloads fill up with one-time-use files. Clear them out now and then to save space.",
                comment: "My Clutter Manager Downloads description."
            )
        }
    }
}

/// Broad file kind used by the Large & Old facet list ("By Kind").
enum MyClutterFileKind: String, CaseIterable {
    case archives
    case videos
    case other

    var title: String {
        switch self {
        case .archives: return String(localized: "Archives", comment: "Large & Old kind facet.")
        case .videos: return String(localized: "Videos", comment: "Large & Old kind facet.")
        case .other: return String(localized: "Other", comment: "Large & Old kind facet.")
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

    static func of(_ url: URL) -> MyClutterFileKind {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return .archives }
        if videoExtensions.contains(ext) { return .videos }
        return .other
    }
}

/// Coarse size bucket used by the Large & Old facet list ("By Size").
enum MyClutterSizeBucket: String, CaseIterable {
    case huge
    case average
    case small

    var title: String {
        switch self {
        case .huge: return String(localized: "Huge", comment: "Large & Old size facet.")
        case .average: return String(localized: "Average", comment: "Large & Old size facet.")
        case .small: return String(localized: "Small", comment: "Large & Old size facet.")
        }
    }

    /// 1000-based thresholds, matching the file-style byte formatting used
    /// throughout the manager: huge ≥ 5 GB, average 1–5 GB, small < 1 GB.
    static func of(_ size: Int64) -> MyClutterSizeBucket {
        if size >= 5_000_000_000 { return .huge }
        if size >= 1_000_000_000 { return .average }
        return .small
    }
}

/// The active facet shown in the Large & Old right pane.
enum MyClutterLargeOldFacet: Hashable {
    case all
    case selected
    case kind(MyClutterFileKind)
    case size(MyClutterSizeBucket)
}

enum MyClutterManagerModel {

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

    /// Total bytes of the files in a facet.
    static func bytes(of files: [ScannedFile]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// Downloads grouped by their source app, ordered by total bytes (largest
    /// first). Files with no recorded source fall into an "Other" bucket.
    static func downloadsBySource(_ items: [DownloadItem]) -> [MyClutterDownloadGroup] {
        var bySource: [String: [DownloadItem]] = [:]
        for item in items {
            let key = item.sourceApp ?? String(localized: "Other", comment: "Downloads bucket for files with no recorded source.")
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
struct MyClutterDownloadGroup: Identifiable, Sendable {
    let source: String
    let bundleID: String?
    let items: [DownloadItem]
    let bytes: Int64
    var id: String { source }
}
