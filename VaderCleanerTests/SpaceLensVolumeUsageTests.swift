// SpaceLensVolumeUsageTests.swift
// Verifies the Space Lens volume gauge math: used/selection fractions, zero-capacity guard, and the "X of Y used" summary.

import XCTest
@testable import VaderCleaner

final class SpaceLensVolumeUsageTests: XCTestCase {

    func test_usedFraction_isUsedOverTotal() {
        let usage = SpaceLensVolumeUsage(volumeName: "Macintosh HD", usedBytes: 1_300, totalBytes: 2_000)
        XCTAssertEqual(usage.usedFraction, 0.65, accuracy: 0.0001)
    }

    func test_usedFraction_zeroTotalIsSafe() {
        let usage = SpaceLensVolumeUsage(volumeName: "X", usedBytes: 100, totalBytes: 0)
        XCTAssertEqual(usage.usedFraction, 0)
    }

    func test_selectionFraction_isClampedToOne() {
        let usage = SpaceLensVolumeUsage(volumeName: "X", usedBytes: 0, totalBytes: 1_000)
        XCTAssertEqual(usage.selectionFraction(forSelected: 250), 0.25, accuracy: 0.0001)
        XCTAssertEqual(usage.selectionFraction(forSelected: 5_000), 1.0)
    }

    func test_formattedSummary_includesUsedAndTotal() {
        let usage = SpaceLensVolumeUsage(
            volumeName: "Macintosh HD",
            usedBytes: 1_300_000_000_000,
            totalBytes: 2_000_000_000_000
        )
        let summary = usage.formattedSummary
        XCTAssertTrue(summary.contains("used"), summary)
        XCTAssertTrue(summary.contains("of"), summary)
        XCTAssertTrue(summary.contains("TB"), summary)
    }
}
