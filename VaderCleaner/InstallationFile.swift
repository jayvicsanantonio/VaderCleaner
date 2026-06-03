// InstallationFile.swift
// Value type describing a leftover installer (disk image or package) discovered in the user's Downloads / Desktop and surfaced on the Applications dashboard.

import Foundation

/// What kind of installer an `InstallationFile` is, used for the row badge and
/// the explanatory copy. Disk images (`.dmg`, `.iso`) and flat installer
/// packages (`.pkg`) are the two shapes the scanner surfaces.
enum InstallationFileKind: String, Hashable, Sendable {
    case diskImage
    case package

    /// Classifies a lowercased file extension, or `nil` when the extension is
    /// not one of the installer types the scanner collects.
    static func forExtension(_ ext: String) -> InstallationFileKind? {
        switch ext.lowercased() {
        case "dmg", "iso": return .diskImage
        case "pkg":        return .package
        default:           return nil
        }
    }
}

/// A single leftover installer file. `id` keys off the path so SwiftUI list
/// identity stays stable across repeated scans and after rows are removed.
struct InstallationFile: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let kind: InstallationFileKind

    var id: String { url.path }
}
