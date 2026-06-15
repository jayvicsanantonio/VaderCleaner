// LargeOldFilesCategory.swift
// Groups a flat Large & Old Files scan into the dashboard's recommendation tiles — type/age lenses, their titles and icons, and the assembly of non-empty tiles with the heaviest one first.

import Foundation

/// One lens over the Large & Old Files scan, surfaced as a dashboard tile.
/// `.videos` / `.archives` / `.other` partition every file by type; `.old`
/// (age) and `.largest` (top by size) are cross-cutting lenses that overlap
/// the type tiles on purpose — each is a different way to slice the same scan.
enum LargeOldFilesCategory: String, CaseIterable, Identifiable {
    case largest
    case old
    case videos
    case archives
    case other

    var id: String { rawValue }

    /// Tile heading and the title of the drill-down review screen.
    var title: String {
        switch self {
        case .largest:
            return String(localized: "Largest Files",
                          comment: "Large & Old Files tile: the biggest files by size.")
        case .old:
            return String(localized: "Old Files",
                          comment: "Large & Old Files tile: files untouched for six months or more.")
        case .videos:
            return String(localized: "Videos",
                          comment: "Large & Old Files tile: movie and recording files.")
        case .archives:
            return String(localized: "Archives & Disk Images",
                          comment: "Large & Old Files tile: compressed archives and disk images.")
        case .other:
            return String(localized: "Other Large Files",
                          comment: "Large & Old Files tile: everything that isn't a video or an archive.")
        }
    }

    /// SF Symbol shown on the tile.
    var icon: String {
        switch self {
        case .largest: return "arrow.up.right.circle.fill"
        case .old: return "clock.arrow.circlepath"
        case .videos: return "film.fill"
        case .archives: return "archivebox.fill"
        case .other: return "doc.fill"
        }
    }

    /// One-line descriptor shown under the tile's size metric.
    var blurb: String {
        switch self {
        case .largest:
            return String(localized: "Your biggest space hogs, ranked by size.",
                          comment: "Large & Old Files Largest tile detail line.")
        case .old:
            return String(localized: "Untouched for six months or more.",
                          comment: "Large & Old Files Old tile detail line.")
        case .videos:
            return String(localized: "Movies and recordings — usually the biggest win.",
                          comment: "Large & Old Files Videos tile detail line.")
        case .archives:
            return String(localized: "Disk images and compressed archives.",
                          comment: "Large & Old Files Archives tile detail line.")
        case .other:
            return String(localized: "Documents and everything else.",
                          comment: "Large & Old Files Other tile detail line.")
        }
    }
}

/// One dashboard tile: a category and the files that fall under it. The
/// aggregates are computed **once** at construction and stored, never derived on
/// access — the view reads `totalBytes`/`oldCount` many times per render across
/// several tiles, and a category can hold hundreds of thousands of files, so a
/// computed `reduce` here would re-scan the whole set on every read and freeze
/// the UI.
struct LargeOldFilesTile: Identifiable, Equatable {
    let category: LargeOldFilesCategory
    let files: [ScannedFile]
    /// Number of files in this tile.
    let count: Int
    /// Summed size of the tile's files, in bytes.
    let totalBytes: Int64
    /// How many of the tile's files are tagged `.oldFile` — feeds the "N older
    /// than 6 months" line without re-scanning the files.
    let oldCount: Int

    var id: String { category.rawValue }

    init(category: LargeOldFilesCategory, files: [ScannedFile]) {
        self.category = category
        self.files = files
        var bytes: Int64 = 0
        var old = 0
        for file in files {
            bytes += file.size
            if file.category == .oldFile { old += 1 }
        }
        self.count = files.count
        self.totalBytes = bytes
        self.oldCount = old
    }
}

/// Pure grouping of a scan into category lenses and dashboard tiles. Free of
/// any view so the bucketing rules stay unit-testable.
enum LargeOldFilesCategorizer {

    /// The "Largest Files" lens caps at this many files — enough to surface the
    /// genuine space hogs without re-listing the whole scan.
    static let largestTileLimit = 20

    /// Extensions classified as video. Matched case-insensitively against the
    /// file's path extension.
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "wmv", "flv", "webm",
        "mpg", "mpeg", "3gp", "ts", "m2ts"
    ]

    /// Extensions classified as a compressed archive or installer disk image.
    /// Excludes the sparse VM/container disk images (`raw`, `sparseimage`,
    /// `sparsebundle`) — the scanner skips those entirely, and a bare `.raw`
    /// that does slip through is a camera photo that belongs in "Other".
    static let archiveExtensions: Set<String> = [
        "zip", "dmg", "iso", "tar", "gz", "tgz", "bz2", "xz",
        "7z", "rar", "pkg", "img", "cdr"
    ]

    /// The files that fall under `category`. For `.largest` this is the top
    /// `largestTileLimit` by size; for `.old` it is age-driven; the rest match
    /// by file extension.
    static func files(
        in category: LargeOldFilesCategory,
        from files: [ScannedFile],
        referenceDate: Date = Date()
    ) -> [ScannedFile] {
        switch category {
        case .largest:
            return Array(files.sorted { $0.size > $1.size }.prefix(largestTileLimit))
        case .old:
            let cutoff = referenceDate.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds)
            return files.filter { file in
                guard let accessed = file.lastAccessDate else { return false }
                return accessed <= cutoff
            }
        case .videos:
            return files.filter { videoExtensions.contains(ext(of: $0)) }
        case .archives:
            return files.filter { archiveExtensions.contains(ext(of: $0)) }
        case .other:
            return files.filter {
                let e = ext(of: $0)
                return !videoExtensions.contains(e) && !archiveExtensions.contains(e)
            }
        }
    }

    /// The dashboard's tiles: one per category that has findings, the primary
    /// type/age lenses ordered heaviest-first (so the caller can promote the
    /// first to a hero card), with the cross-cutting "Largest Files" lens
    /// appended only when there are more files than it caps at — otherwise it
    /// would just duplicate the whole result set.
    static func tiles(from files: [ScannedFile], referenceDate: Date = Date()) -> [LargeOldFilesTile] {
        let primary: [LargeOldFilesCategory] = [.videos, .archives, .old, .other]
        var tiles = primary
            .map { LargeOldFilesTile(category: $0, files: self.files(in: $0, from: files, referenceDate: referenceDate)) }
            .filter { !$0.files.isEmpty }
            .sorted { $0.totalBytes > $1.totalBytes }

        if files.count > largestTileLimit {
            tiles.append(LargeOldFilesTile(category: .largest,
                                           files: self.files(in: .largest, from: files, referenceDate: referenceDate)))
        }
        return tiles
    }

    private static func ext(of file: ScannedFile) -> String {
        file.url.pathExtension.lowercased()
    }
}
