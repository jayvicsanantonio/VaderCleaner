// ReleaseNotesSummaryTests.swift
// Tests reducing an appcast or App Store release-notes blob to one plain-text summary line — tag stripping, entity decoding, whitespace collapsing, truncation, and the empty cases that must yield nil.

import XCTest
@testable import VaderCleaner

final class ReleaseNotesSummaryTests: XCTestCase {

    // MARK: - Plain text

    /// Plain-text notes pass through intact. Telegram's appcast is exactly
    /// this shape, so the common case must not be mangled by the HTML
    /// handling that other feeds need.
    func test_summary_passesPlainTextThrough() {
        XCTAssertEqual(
            ReleaseNotesSummary.summary(from: "• Bug fixes, minor improvements, and more."),
            "• Bug fixes, minor improvements, and more."
        )
    }

    /// Leading and trailing whitespace is trimmed.
    func test_summary_trimsSurroundingWhitespace() {
        XCTAssertEqual(ReleaseNotesSummary.summary(from: "\n  Fixed a crash.  \n"), "Fixed a crash.")
    }

    /// Newlines and runs of spaces collapse to single spaces so the result
    /// fits a one-line row without reflowing the layout.
    func test_summary_collapsesInternalWhitespace() {
        XCTAssertEqual(
            ReleaseNotesSummary.summary(from: "Fixed a crash.\n\n  Added   a  setting."),
            "Fixed a crash. Added a setting."
        )
    }

    // MARK: - HTML

    /// Many appcasts put HTML in `<description>`. Tags are stripped rather
    /// than rendered — the row shows text, not markup.
    func test_summary_stripsHTMLTags() {
        XCTAssertEqual(
            ReleaseNotesSummary.summary(from: "<ul><li>Fixed a crash</li><li>Added a setting</li></ul>"),
            "Fixed a crash Added a setting"
        )
    }

    /// Attributes inside a tag are part of the tag, not the text.
    func test_summary_stripsTagsCarryingAttributes() {
        XCTAssertEqual(
            ReleaseNotesSummary.summary(from: #"<a href="https://example.com/x?a=1">Details</a>"#),
            "Details"
        )
    }

    /// A block tag must not weld two words together — `<br>` and friends
    /// are word boundaries.
    func test_summary_treatsTagsAsWordBoundaries() {
        XCTAssertEqual(
            ReleaseNotesSummary.summary(from: "Fixed a crash<br>Added a setting"),
            "Fixed a crash Added a setting"
        )
    }

    /// The entities that actually appear in release notes are decoded, so
    /// the row doesn't show raw `&amp;`.
    func test_summary_decodesCommonEntities() {
        XCTAssertEqual(
            ReleaseNotesSummary.summary(from: "Cut &amp; paste, &quot;smart&quot; quotes &lt;3 &nbsp;fixed"),
            "Cut & paste, \"smart\" quotes <3 fixed"
        )
    }

    /// `&amp;lt;` must decode to `&lt;`, not to `<` — decoding ampersands
    /// last would otherwise let escaped markup reappear as markup.
    func test_summary_decodesAmpersandWithoutReopeningEntities() {
        XCTAssertEqual(ReleaseNotesSummary.summary(from: "a &amp;lt; b"), "a &lt; b")
    }

    /// An unrecognised entity is left alone rather than dropped.
    func test_summary_leavesUnknownEntitiesIntact() {
        XCTAssertEqual(ReleaseNotesSummary.summary(from: "50 &euro; off"), "50 &euro; off")
    }

    // MARK: - Length

    /// Long notes are truncated so one verbose release can't dominate the
    /// list. The ellipsis signals there is more to read.
    func test_summary_truncatesLongNotes() {
        let long = String(repeating: "a", count: ReleaseNotesSummary.maximumLength + 50)
        let summary = ReleaseNotesSummary.summary(from: long)
        XCTAssertEqual(summary?.count, ReleaseNotesSummary.maximumLength + 1)
        XCTAssertTrue(summary?.hasSuffix("…") == true)
    }

    /// Notes exactly at the limit are not truncated.
    func test_summary_keepsNotesAtExactlyTheLimit() {
        let exact = String(repeating: "a", count: ReleaseNotesSummary.maximumLength)
        XCTAssertEqual(ReleaseNotesSummary.summary(from: exact), exact)
    }

    // MARK: - Empty

    /// Nil in, nil out.
    func test_summary_nilInputYieldsNil() {
        XCTAssertNil(ReleaseNotesSummary.summary(from: nil))
    }

    /// Content that reduces to nothing yields nil rather than an empty
    /// string, so the UI has one condition to test.
    func test_summary_contentReducingToNothingYieldsNil() {
        for input in ["", "   \n  ", "<p></p>", "<div><br></div>"] {
            XCTAssertNil(ReleaseNotesSummary.summary(from: input), "Expected nil for \(input)")
        }
    }
}
