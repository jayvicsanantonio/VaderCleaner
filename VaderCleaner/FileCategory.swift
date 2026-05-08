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
    var color: Color {
        switch self {
        case .documents: return .blue
        case .media:     return .purple
        case .apps:      return .orange
        case .system:    return .red
        case .other:     return .gray
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

    /// Path-prefix heuristic for directories. `~/Library`, `/System`,
    /// `/usr`, `/private` are the canonical system locations on macOS;
    /// anything underneath them is treated as system content. Everything
    /// else falls into `.other`, which is the right answer for user-managed
    /// directories like `~/Projects` or `/Users/example/Documents`.
    private static func categoryForDirectoryPath(_ path: String) -> FileCategory {
        if path.hasPrefix("/System") { return .system }
        if path.hasPrefix("/usr")    { return .system }
        if path.hasPrefix("/private") { return .system }
        // `/Library/...` covers both the system-wide Library and the
        // per-user `~/Library` (which expands to `/Users/<name>/Library`).
        // The substring check is sufficient — there's no legitimate path
        // containing `/Library/` that the user manages by hand.
        if path.contains("/Library/") { return .system }
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
