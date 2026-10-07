// UnsupportedApp.swift
// Value type pairing an installed app with the reason it can't run on the current macOS, surfaced on the Applications dashboard's Unsupported card.

import Foundation

/// Why an installed app is flagged as unsupported. Phase 3 detects the
/// clearest "won't launch" signal — an executable with no architecture the
/// current macOS can run (no `arm64` and no `x86_64` slice, e.g. a 32-bit
/// Intel or PowerPC binary).
public enum UnsupportedAppReason: String, Hashable, Sendable {
    case incompatibleArchitecture
}

/// A single installed app the scanner believes cannot run on this Mac. `id`
/// keys off the underlying `AppInfo.id` (the bundle path) so SwiftUI list
/// identity stays stable across scans and after rows are removed.
public struct UnsupportedApp: Identifiable, Hashable, Sendable {
    public let app: AppInfo
    public let reason: UnsupportedAppReason

    public var id: String { app.id }
}
