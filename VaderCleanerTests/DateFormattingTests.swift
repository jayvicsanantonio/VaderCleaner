// DateFormattingTests.swift
// Pins the two shared date styles so a surface can't quietly drift onto its own DateFormatter again.

import XCTest
@testable import VaderCleaner

/// Unit tests for `DateFormatting`. The assertions compare against a locally
/// configured `DateFormatter` rather than a literal string, because the output
/// is locale- and timezone-dependent — what these lock down is the *style*,
/// which is the thing three separate copies had to agree on.
final class DateFormattingTests: XCTestCase {

    private let sample = Date(timeIntervalSince1970: 1_700_000_000)

    func test_formattedDate_usesMediumDateWithNoTime() {
        let expected = DateFormatter()
        expected.dateStyle = .medium
        expected.timeStyle = .none

        XCTAssertEqual(formattedDate(sample), expected.string(from: sample))
    }

    func test_formattedDateTime_usesMediumDateWithShortTime() {
        let expected = DateFormatter()
        expected.dateStyle = .medium
        expected.timeStyle = .short

        XCTAssertEqual(formattedDateTime(sample), expected.string(from: sample))
    }

    /// The two styles must stay distinguishable — the date-only form is what
    /// the list columns use, and the form with a time is what the Space Lens
    /// hover card shows.
    func test_theTwoStylesDiffer() {
        XCTAssertNotEqual(formattedDate(sample), formattedDateTime(sample))
    }

    func test_formattedDate_isStableAcrossCalls() {
        XCTAssertEqual(formattedDate(sample), formattedDate(sample))
        XCTAssertEqual(formattedDateTime(sample), formattedDateTime(sample))
    }

    /// The shared formatters are lock-guarded rather than main-actor bound, so
    /// concurrent formatting has to stay correct as well as safe.
    func test_formattingIsSafeFromConcurrentCallers() async {
        // Bound to a local rather than read off `self`: the task closures are
        // `@Sendable` and an XCTestCase is not.
        let date = sample
        let expected = formattedDateTime(date)

        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<200 {
                group.addTask { formattedDateTime(date) }
            }
            var all: [String] = []
            for await value in group { all.append(value) }
            return all
        }

        XCTAssertEqual(results.count, 200)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }
}
