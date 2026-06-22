// ScanCategory.swift
// Stable enum tagging every file the scanner returns so the UI and aggregator can group, label, and persist results.

import Foundation

/// The kind of file or directory a scanner returned. Used by `ScannedFile`,
/// surfaced in the System Junk preview list, and persisted in scan reports —
/// raw values are therefore stable string keys, not auto-derived from the
/// case name.
///
/// New cases must be appended (never inserted), and existing raw values must
/// not change, or stored preferences/reports from older builds will fail to
/// decode.
enum ScanCategory: String, CaseIterable, Codable, Hashable {
    case systemCache
    case userCache
    case systemLogs
    case userLogs
    case languageFiles
    case mailAttachments
    case iosBackups
    case trash
    case largeFile
    case oldFile
    case xcodeJunk
    case documentVersions

    /// User-facing label used in the System Junk preview rows and the
    /// Smart Scan summary cards. Kept on the enum so every caller renders
    /// the same string.
    var displayName: String {
        switch self {
        case .systemCache: return "System Caches"
        case .userCache: return "User Caches"
        case .systemLogs: return "System Logs"
        case .userLogs: return "User Logs"
        case .languageFiles: return "Language Files"
        case .mailAttachments: return "Mail Attachments"
        case .iosBackups: return "iOS Backups"
        case .trash: return "Trash"
        case .largeFile: return "Large Files"
        case .oldFile: return "Old Files"
        case .xcodeJunk: return "Xcode Junk"
        case .documentVersions: return "Document Versions"
        }
    }
}
