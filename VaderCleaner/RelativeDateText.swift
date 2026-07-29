// RelativeDateText.swift
// Thread-safe relative-date strings ("8 months ago") shared by the Review screens that build their rows off the main actor.

import Foundation

/// Relative-date text for row subtitles, formatted the way the rest of the app
/// reports elapsed time.
///
/// Thread-safe via a lock (`@unchecked Sendable`, the same discipline as
/// `CleanupManagerStore`): the Review screens build their sections on a
/// background pass, so a shared formatter would otherwise be reachable from
/// several concurrency domains at once. The instance is kept rather than built
/// per row because construction is comparatively expensive and the builders run
/// once per row.
///
/// `RelativeDateTimeFormatter` is deliberately retained over the newer
/// `Date.RelativeFormatStyle`: the formatter truncates toward the smaller unit
/// where the format style rounds to nearest, so 180 days reads "5 months ago"
/// rather than "6 months ago". The Review copy promises files "you haven't
/// opened in over six months", and rounding up would contradict it.
enum RelativeDateText {

    private final class Formatter: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter = RelativeDateTimeFormatter()

        func string(for date: Date, relativeTo reference: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.localizedString(for: date, relativeTo: reference)
        }
    }

    private static let shared = Formatter()

    /// "8 months ago" — `date` expressed relative to `reference`.
    static func string(for date: Date, relativeTo reference: Date = Date()) -> String {
        shared.string(for: date, relativeTo: reference)
    }
}
