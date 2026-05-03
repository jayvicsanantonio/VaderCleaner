// PrivacyPermissionChecker.swift
// Detects whether VaderCleaner has been granted Full Disk Access by attempting to read a TCC-gated path.

import Foundation

/// Probes Full Disk Access by attempting to read a file that is normally protected by TCC.
///
/// `FileManager.default.fileExists(atPath:)` does NOT trigger TCC and returns `true` even
/// when access is denied — the only reliable detection is to actually open the file for
/// reading. The default probe is `~/Library/Application Support/com.apple.TCC/TCC.db`,
/// which exists on every macOS install and is gated by FDA. Tests pass an alternate
/// `testPath` so that the result is deterministic regardless of host TCC state.
enum PrivacyPermissionChecker {

    /// Canonical FDA-gated path used as the default probe.
    static var defaultTestPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// Returns `true` if the given path can be opened for reading. With the default
    /// `testPath`, this indicates Full Disk Access has been granted to the host process.
    static func hasFullDiskAccess(testPath: URL = defaultTestPath) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: testPath) else {
            return false
        }
        try? handle.close()
        return true
    }
}
