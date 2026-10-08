// ReleaseNotesSummaryTests.swift
// Tests reducing an appcast or App Store release-notes blob to one plain-text summary line — tag stripping, entity decoding, whitespace collapsing, truncation, and the empty cases that must yield nil.

import Testing
@testable import VaderCleaner

@Suite
struct ReleaseNotesSummaryTests {

    // MARK: - Plain text

    /// Plain-text notes pass through intact. Telegram's appcast is exactly
    /// this shape, so the common case must not be mangled by the HTML
    /// handling that other feeds need.
    @Test
    func summary_passesPlainTextThrough() {
        #expect(
            ReleaseNotesSummary.summary(from: "• Bug fixes, minor improvements, and more.")
                == "• Bug fixes, minor improvements, and more."
        )
    }

    /// Leading and trailing whitespace is trimmed.
    @Test
    func summary_trimsSurroundingWhitespace() {
        #expect(ReleaseNotesSummary.summary(from: "\n  Fixed a crash.  \n") == "Fixed a crash.")
    }

    /// Newlines and runs of spaces collapse to single spaces so the result
    /// fits a one-line row without reflowing the layout.
    @Test
    func summary_collapsesInternalWhitespace() {
        #expect(
            ReleaseNotesSummary.summary(from: "Fixed a crash.\n\n  Added   a  setting.")
                == "Fixed a crash. Added a setting."
        )
    }

    // MARK: - HTML

    /// Many appcasts put HTML in `<description>`. Tags are stripped rather
    /// than rendered — the row shows text, not markup.
    @Test
    func summary_stripsHTMLTags() {
        #expect(
            ReleaseNotesSummary.summary(from: "<ul><li>Fixed a crash</li><li>Added a setting</li></ul>")
                == "Fixed a crash Added a setting"
        )
    }

    /// Attributes inside a tag are part of the tag, not the text.
    @Test
    func summary_stripsTagsCarryingAttributes() {
        #expect(
            ReleaseNotesSummary.summary(from: #"<a href="https://example.com/x?a=1">Details</a>"#) == "Details"
        )
    }

    /// A block tag must not weld two words together — `<br>` and friends
    /// are word boundaries.
    @Test
    func summary_treatsTagsAsWordBoundaries() {
        #expect(
            ReleaseNotesSummary.summary(from: "Fixed a crash<br>Added a setting") == "Fixed a crash Added a setting"
        )
    }

    /// The entities that actually appear in release notes are decoded, so
    /// the row doesn't show raw `&amp;`.
    @Test
    func summary_decodesCommonEntities() {
        #expect(
            ReleaseNotesSummary.summary(from: "Cut &amp; paste, &quot;smart&quot; quotes &lt;3 &nbsp;fixed")
                == "Cut & paste, \"smart\" quotes <3 fixed"
        )
    }

    /// `&amp;lt;` must decode to `&lt;`, not to `<` — decoding ampersands
    /// last would otherwise let escaped markup reappear as markup.
    @Test
    func summary_decodesAmpersandWithoutReopeningEntities() {
        #expect(ReleaseNotesSummary.summary(from: "a &amp;lt; b") == "a &lt; b")
    }

    /// An unrecognised entity is left alone rather than dropped.
    @Test
    func summary_leavesUnknownEntitiesIntact() {
        #expect(ReleaseNotesSummary.summary(from: "50 &euro; off") == "50 &euro; off")
    }

    // MARK: - Length

    /// Long notes are truncated so one verbose release can't dominate the
    /// list. The ellipsis signals there is more to read.
    @Test
    func summary_truncatesLongNotes() {
        let long = String(repeating: "a", count: ReleaseNotesSummary.maximumLength + 50)
        let summary = ReleaseNotesSummary.summary(from: long)
        #expect(summary?.count == ReleaseNotesSummary.maximumLength + 1)
        #expect(summary?.hasSuffix("…") == true)
    }

    /// Notes exactly at the limit are not truncated.
    @Test
    func summary_keepsNotesAtExactlyTheLimit() {
        let exact = String(repeating: "a", count: ReleaseNotesSummary.maximumLength)
        #expect(ReleaseNotesSummary.summary(from: exact) == exact)
    }

    // MARK: - Empty

    /// Nil in, nil out.
    @Test
    func summary_nilInputYieldsNil() {
        #expect(ReleaseNotesSummary.summary(from: nil) == nil)
    }

    /// Content that reduces to nothing yields nil rather than an empty
    /// string, so the UI has one condition to test.
    @Test
    func summary_contentReducingToNothingYieldsNil() {
        for input in ["", "   \n  ", "<p></p>", "<div><br></div>"] {
            #expect(ReleaseNotesSummary.summary(from: input) == nil, "Expected nil for \(input)")
        }
    }
}
