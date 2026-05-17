// HelperConnectionError.swift
// Single source of truth for privileged-helper connection failures — the canonical user-facing copy and the error-to-message mapper shared by every helper-backed view model.

import Foundation

/// Raised when the privileged `VaderCleanerHelper` cannot be reached. Replaces
/// the ad-hoc `NSError(... "Helper unavailable")` sentinels each helper caller
/// used to build, so the user-facing copy lives in exactly one place.
enum HelperConnectionError: LocalizedError {
    case unavailable

    /// The exact copy Prompt 27 requires for a helper connection failure.
    static let message =
        "VaderCleaner Helper is not responding. Try restarting the app."

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return Self.message
        }
    }

    /// Maps an arbitrary error raised on a helper-backed code path to the
    /// string the UI should display. Connection-class failures (this enum,
    /// the `NSXPCConnection` NSCocoaError codes, and the legacy sentinel)
    /// collapse to the friendly copy; everything else passes through its own
    /// localized description so a locked file or permission denial still
    /// tells the user what actually went wrong.
    static func userFacingMessage(for error: Error) -> String {
        if error is HelperConnectionError {
            return message
        }

        let nsError = error as NSError

        // NSXPCConnection reports a dropped/unavailable connection as
        // NSCocoaErrorDomain 4097 (interrupted), 4099 (invalid), or 4101
        // (reply invalid). The system's own localizedDescription for these
        // is the cryptic "Couldn't communicate with a helper application."
        if nsError.domain == NSCocoaErrorDomain,
           [4097, 4099, 4101].contains(nsError.code) {
            return message
        }

        // Defensive: any code path still constructing the old
        // "Helper unavailable" sentinel normalizes to the same copy.
        if nsError.localizedDescription == "Helper unavailable" {
            return message
        }

        return error.localizedDescription
    }
}
