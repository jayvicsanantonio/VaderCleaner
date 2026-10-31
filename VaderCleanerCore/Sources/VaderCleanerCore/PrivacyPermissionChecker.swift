// PrivacyPermissionChecker.swift
// Detects whether VaderCleaner has been granted Full Disk Access by attempting to read TCC-gated paths.

import Foundation

/// Probes Full Disk Access by attempting to read files that are normally protected by TCC.
///
/// `FileManager.default.fileExists(atPath:)` does NOT trigger TCC and returns `true` even
/// when access is denied — the only reliable detection is to actually open the file for
/// reading. Tests pass alternate `testPaths` so that the result is deterministic regardless
/// of host TCC state.
public enum PrivacyPermissionChecker {

    /// Deep-link to System Settings → Privacy & Security → Full Disk Access. The
    /// identifier is the bundle ID of the installed Settings extension; a link to
    /// one that doesn't exist does nothing at all, with no error to notice.
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    /// FDA-gated files used as the default probes. Reading any one of them proves
    /// access, and there are several because a single file can vanish in a macOS
    /// release, which would otherwise read as "denied" no matter what the user
    /// grants. None sit in another app's container, so a probe can't raise the
    /// system's "access data from other apps" prompt.
    public static var defaultTestPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/Bookmarks.plist"),
        ]
    }

    /// Returns `true` if any of the given paths can be opened for reading. With the
    /// default `testPaths`, this indicates Full Disk Access has been granted to the
    /// host process.
    public static func hasFullDiskAccess(testPaths: [URL] = defaultTestPaths) -> Bool {
        testPaths.contains { path in
            guard let handle = try? FileHandle(forReadingFrom: path) else {
                return false
            }
            try? handle.close()
            return true
        }
    }
}
