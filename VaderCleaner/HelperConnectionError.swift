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
        isConnectionFailure(error) ? message : error.localizedDescription
    }

    /// True when `error` means the privileged helper couldn't be reached (this
    /// enum, or an `NSXPCConnection` connection-class `NSCocoaError`), as
    /// opposed to a substantive failure the helper itself reported. Callers
    /// use this to offer a "Reinstall Helper" recovery rather than a plain
    /// retry.
    ///
    /// `NSXPCConnection` reports a dropped or refused connection as
    /// `NSCocoaErrorDomain` 4097 (interrupted), 4099 (invalid), 4101 (reply
    /// invalid), or 4102 (the peer failed the code-signing requirement the app
    /// sets on the connection). The first three carry the cryptic "Couldn't
    /// communicate with a helper application."; 4102 reads "The code signature
    /// requirement failed.", which is just as opaque and means the same thing
    /// for the user — the helper on disk isn't the one this app can talk to, and
    /// re-registering it is the fix.
    static func isConnectionFailure(_ error: Error) -> Bool {
        if error is HelperConnectionError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && [4097, 4099, 4101, 4102].contains(nsError.code)
    }
}
