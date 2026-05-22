// FileCategory.swift
// Maps a DiskNode to a coarse type bucket (documents/media/apps/system/other) used to color tiles in the Space Lens treemap.

import Foundation
import SwiftUI

/// Coarse category assigned to every tile in the Space Lens treemap. The
/// categories are deliberately broad — finer-grained types (e.g. "Office
/// document" vs. "PDF") would split colors into a pattern the eye can no
/// longer parse at a glance, defeating the whole point of the colored
/// visualization.
enum FileCategory: Hashable {
    /// Office-style documents: text, spreadsheets, presentations, markup.
    case documents
    /// Images, audio, video.
    case media
    /// Application bundles. Stored as `.app` directories on disk; the
    /// categorizer recognises the bundle extension before it falls into
    /// the directory branch.
    case apps
    /// Library contents, system frameworks, logs, plists. Anything the user
    /// rarely manages by hand.
    case system
    /// Fallback bucket — unknown extensions, plain user directories.
    case other

    /// Tile color in the treemap. Held with the enum rather than at the
    /// view layer so a future use (legend, tooltip swatch) can read it
    /// directly without re-implementing the mapping.
    ///
    /// All five shades sit in the crimson family so the treemap stays inside
    /// the Vader identity; they are spread bright → deep across lightness so
    /// neighboring tiles remain distinguishable at a glance. `.media` is the
    /// theme anchor — it is exactly `Color.vaderCrimson`. `.other` is a
    /// desaturated dusty crimson so the fallback bucket still reads as the
    /// quiet, neutral category.
    var color: Color {
        switch self {
        case .documents: return Color(red: 0.95, green: 0.30, blue: 0.36)
        case .media:     return .vaderCrimson
        case .apps:      return Color(red: 0.66, green: 0.09, blue: 0.15)
        case .system:    return Color(red: 0.46, green: 0.07, blue: 0.12)
        case .other:     return Color(red: 0.40, green: 0.20, blue: 0.24)
        }
    }

    /// Pretty label used by tooltips and the (eventual) legend. Localized
    /// via `String(localized:)` so a future translation pass picks them up.
    var displayName: String {
        switch self {
        case .documents: return String(localized: "Documents")
        case .media:     return String(localized: "Media")
        case .apps:      return String(localized: "Apps")
        case .system:    return String(localized: "System")
        case .other:     return String(localized: "Other")
        }
    }

    /// Categorize a `DiskNode` based on its URL and directory flag.
    ///
    /// Resolution order matters: `.app` bundles are technically directories,
    /// so we check the extension first; otherwise every application would
    /// land in the directory branch and pick up the `.system` / `.other`
    /// fallback. After the bundle check, directories route by path prefix
    /// (system locations) and files route by extension.
    static func from(node: DiskNode) -> FileCategory {
        let ext = node.url.pathExtension.lowercased()

        if ext == "app" { return .apps }

        if node.isDirectory {
            return categoryForDirectoryPath(node.url.path)
        }

        if Self.documentExtensions.contains(ext) { return .documents }
        if Self.mediaExtensions.contains(ext)    { return .media }
        if Self.systemExtensions.contains(ext)   { return .system }
        return .other
    }

    // MARK: - Internals

    /// Path-component heuristic for directories. `~/Library`, `/Library`,
    /// `/System`, `/usr`, `/private` are the canonical system locations on
    /// macOS; the directory itself and anything underneath them is treated
    /// as system content. Everything else falls into `.other`, which is the
    /// right answer for user-managed directories like `~/Projects` or
    /// `/Users/example/Documents`.
    ///
    /// **Component-based, not substring-based.** `path.hasPrefix("/usr")`
    /// matches a user's own `/Users/example/usr_data`, and
    /// `path.contains("/Library/")` matches `/Users/example/Projects/Library/foo`.
    /// Both would be misclassified as system. Splitting on `/` and comparing
    /// whole components avoids those false positives, and incidentally lets
    /// us recognize the Library directory itself (e.g. the top-level
    /// `~/Library` tile in a Space Lens scan of the home folder), which
    /// the substring rule missed because the path doesn't end with a slash.
    private static func categoryForDirectoryPath(_ path: String) -> FileCategory {
        // `pathComponents` returns `["/", "System", ...]` for an absolute
        // path, so the second element (index 1) is the first real component.
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 2 else { return .other }

        switch components[1] {
        case "System", "usr", "private":
            return .system
        case "Library":
            // `/Library` and `/Library/...` — system-wide Library.
            return .system
        default:
            break
        }

        // `~/Library` expands to `/Users/<name>/Library`. Match the
        // four-component shape exactly (root + "Users" + name + "Library")
        // rather than checking `components.contains("Library")`, which
        // would still misclassify a user-created `~/Projects/Library/...`.
        if components.count >= 4,
           components[1] == "Users",
           components[3] == "Library" {
            return .system
        }

        return .other
    }

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "txt", "rtf", "pages",
        "xls", "xlsx", "numbers", "ppt", "pptx", "key",
        "md", "csv", "odt", "epub"
    ]

    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "raw", "webp", "svg",
        "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv",
        "mp3", "wav", "aac", "flac", "m4a", "ogg", "opus"
    ]

    private static let systemExtensions: Set<String> = [
        "dylib", "framework", "kext", "plist", "log", "ips", "diag",
        "bundle", "appex"
    ]
}
