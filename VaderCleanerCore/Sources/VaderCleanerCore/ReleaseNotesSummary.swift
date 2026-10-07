// ReleaseNotesSummary.swift
// Reduces an appcast or App Store release-notes blob to a single plain-text line — appcast descriptions are HTML in some feeds and plain text in others, and the update row shows text either way.

import Foundation

/// Turns release-notes content into one display line.
///
/// Deliberately not an HTML renderer. `NSAttributedString(html:)` would
/// parse this properly but requires the main thread, is slow enough to
/// matter per row, and pulls a full WebKit-adjacent parser in to render
/// what is almost always a short bullet list. Stripping tags and decoding
/// the handful of entities that actually appear gets the same result for
/// this content at a fraction of the cost.
enum ReleaseNotesSummary {

    /// Longest summary kept before truncation. Sized so one verbose
    /// release can't dominate the update list.
    static let maximumLength = 240

    /// Entities common in real release notes. Ampersand is decoded
    /// **last** so `&amp;lt;` yields `&lt;` rather than reopening as
    /// markup.
    private static let entities: [(escaped: String, plain: String)] = [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&nbsp;", " "),
        ("&amp;", "&"),
    ]

    /// A single plain-text line, or `nil` when the content carries no
    /// text. Nil rather than an empty string so callers have one
    /// condition to test.
    static func summary(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        // Tags become spaces rather than vanishing, so `a<br>b` reads as
        // two words instead of one.
        var text = ""
        var insideTag = false
        for character in raw {
            switch character {
            case "<":
                insideTag = true
                text.append(" ")
            case ">":
                insideTag = false
            default:
                if !insideTag { text.append(character) }
            }
        }

        for (escaped, plain) in entities {
            text = text.replacingOccurrences(of: escaped, with: plain)
        }

        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength)) + "…"
    }
}
