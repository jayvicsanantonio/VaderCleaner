// DateFormattingTests.swift
// Pins the two shared date styles so a surface can't quietly drift onto its own DateFormatter again.

import Foundation
import Testing
@testable import VaderCleanerCore

/// Tests for `DateFormatting`. The assertions compare against a locally
/// configured `DateFormatter` rather than a literal string, because the output
/// is locale- and timezone-dependent — what these lock down is the *style*,
/// which is the thing three separate copies had to agree on.
@Suite
struct DateFormattingTests {

    private let sample = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func formattedDate_usesMediumDateWithNoTime() {
        let expected = DateFormatter()
        expected.dateStyle = .medium
        expected.timeStyle = .none

        #expect(formattedDate(sample) == expected.string(from: sample))
    }

    @Test
    func formattedDateTime_usesMediumDateWithShortTime() {
        let expected = DateFormatter()
        expected.dateStyle = .medium
        expected.timeStyle = .short

        #expect(formattedDateTime(sample) == expected.string(from: sample))
    }

    /// The two styles must stay distinguishable — the date-only form is what
    /// the list columns use, and the form with a time is what the Space Lens
    /// hover card shows.
    @Test
    func theTwoStylesDiffer() {
        #expect(formattedDate(sample) != formattedDateTime(sample))
    }

    @Test
    func formattedDate_isStableAcrossCalls() {
        #expect(formattedDate(sample) == formattedDate(sample))
        #expect(formattedDateTime(sample) == formattedDateTime(sample))
    }

    /// The shared formatters are lock-guarded rather than main-actor bound, so
    /// concurrent formatting has to stay correct as well as safe.
    @Test
    func formattingIsSafeFromConcurrentCallers() async {
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

        #expect(results.count == 200)
        #expect(results.allSatisfy { $0 == expected })
    }
}
