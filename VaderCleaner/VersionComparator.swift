// VersionComparator.swift
// Semantic version comparison used by the App Updater to decide whether a remote version is newer than the locally-installed one.

import Foundation

/// Pure helpers for comparing dotted version strings ("1.0.0", "1.2.3-beta",
/// "1.2"). The implementation deliberately does NOT pull in a full SemVer
/// parser — Mac apps emit a variety of version strings that don't conform
/// strictly to SemVer, and the App Updater only ever needs to answer "is A
/// newer than B?" not "what is the pre-release identifier?".
enum VersionComparator {

    /// Whether `version` represents a release strictly newer than `other`.
    /// Equal versions return `false`.
    static func isNewer(version: String, than other: String) -> Bool {
        compare(version, other) == .orderedDescending
    }

    /// Component-wise numeric comparison with zero-padding for differing
    /// lengths. A non-zero trailing component beats a shorter version
    /// ("1.0.0.1" > "1.0.0"). Components are parsed with their leading
    /// digits only, so "4-beta" maps to 4 — enough to keep us correct on
    /// the common cases without committing to a full pre-release grammar.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftTokens = lhs.split(separator: ".")
        let rightTokens = rhs.split(separator: ".")
        let maxCount = max(leftTokens.count, rightTokens.count)
        for index in 0..<maxCount {
            let left = index < leftTokens.count ? leadingNumber(in: String(leftTokens[index])) : 0
            let right = index < rightTokens.count ? leadingNumber(in: String(rightTokens[index])) : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Extracts the numeric value of `token`, skipping any leading
    /// non-digit characters first. "v12" → 12, "12-beta" → 12, "beta" → 0.
    /// The leading-skip matters because Sparkle feeds (and some Mac apps)
    /// commonly tag releases as "v1.2.3"; without it every component would
    /// parse to 0 and a real update would look identical to the installed
    /// build. Values that overflow `UInt64` fall back to 0 so we never
    /// trap on malformed input — the caller treats those as equal-or-older.
    private static func leadingNumber(in token: String) -> UInt64 {
        var digits = ""
        var seenDigit = false
        for character in token {
            let isDigit = character.isASCII && character.isNumber
            if isDigit {
                digits.append(character)
                seenDigit = true
            } else if seenDigit {
                // Stop at the first non-digit *after* the numeric run so
                // "1-beta" stays 1 rather than swallowing later digits.
                break
            }
            // Leading non-digits (the "v" in "v1.2") are skipped.
        }
        return UInt64(digits) ?? 0
    }
}
