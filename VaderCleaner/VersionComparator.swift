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

    /// Extracts the leading numeric prefix from `token`. "12-beta" → 12.
    /// "beta" → 0. Values that overflow `UInt64` fall back to 0 so we never
    /// trap on malformed input — the caller treats those as equal-or-older.
    private static func leadingNumber(in token: String) -> UInt64 {
        var digits = ""
        for character in token {
            guard character.isASCII, character.isNumber else { break }
            digits.append(character)
        }
        return UInt64(digits) ?? 0
    }
}
