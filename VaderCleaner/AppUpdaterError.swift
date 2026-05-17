// AppUpdaterError.swift
// User-facing copy and the error-to-message mapper for App Updater failures — rewrites URL-loading failures into a clear, actionable string instead of Foundation's terse network descriptions.

import Foundation

/// Surfaced when an update check cannot complete. Today the only modelled
/// case is loss of network connectivity, which is by far the most common
/// reason the iTunes Search API / Sparkle feeds become unreachable.
enum AppUpdaterError: LocalizedError {
    case networkUnavailable

    /// The exact copy Prompt 27 requires for an offline update check.
    static let networkMessage =
        "Could not check for updates. Check your internet connection."

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return Self.networkMessage
        }
    }

    /// Maps an arbitrary error raised while checking for updates to the
    /// string the UI should display. URL-loading failures (offline, DNS,
    /// host unreachable, timeout — in both `URLError` and bridged
    /// `NSURLErrorDomain` form) collapse to the network copy; everything
    /// else passes through its own localized description so a filesystem
    /// failure during app discovery still reads accurately.
    static func userFacingMessage(for error: Error) -> String {
        if error is AppUpdaterError {
            return networkMessage
        }
        if error is URLError {
            return networkMessage
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return networkMessage
        }
        return error.localizedDescription
    }
}
