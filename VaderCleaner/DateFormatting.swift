// DateFormatting.swift
// The app's shared date-to-string formatting, so every surface stamps a file's dates the same way.

import Foundation

/// Medium date, no time ("Nov 14, 2023") — the form the list columns use, where
/// a row shows when a file was last touched and the time of day would be noise.
func formattedDate(_ date: Date) -> String {
    LockedDateFormatter.dateOnly.string(from: date)
}

/// Medium date with a short time ("Nov 14, 2023 at 2:13 PM") — used where a
/// single item is being inspected closely enough for the time to matter, such
/// as the Space Lens hover card.
func formattedDateTime(_ date: Date) -> String {
    LockedDateFormatter.dateAndTime.string(from: date)
}

/// A reusable `DateFormatter` guarded so it can be shared safely.
///
/// Same discipline as `LockedByteFormatter` next door, and for the same reason:
/// `DateFormatter` carries no documented thread-safety guarantee, and building
/// one is expensive enough that the surfaces which format a column of them
/// should not pay for it per row. `DateFormatter` has no type-method escape
/// hatch the way `ByteCountFormatter` does, so the lock is the whole mechanism
/// rather than a fallback for awkward configurations.
private final class LockedDateFormatter: @unchecked Sendable {

    static let dateOnly = LockedDateFormatter(dateStyle: .medium, timeStyle: .none)
    static let dateAndTime = LockedDateFormatter(dateStyle: .medium, timeStyle: .short)

    private let lock = NSLock()
    private let formatter: DateFormatter

    init(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        self.formatter = formatter
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
