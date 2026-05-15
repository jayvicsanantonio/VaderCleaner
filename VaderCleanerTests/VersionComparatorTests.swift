// VersionComparatorTests.swift
// Tests semantic version comparison helpers used by the App Updater to decide whether a remotely-discovered version is newer than the locally-installed one.

import XCTest
@testable import VaderCleaner

final class VersionComparatorTests: XCTestCase {

    // MARK: - isNewer

    func test_isNewer_returnsTrueForPatchBump() {
        XCTAssertTrue(VersionComparator.isNewer(version: "1.0.1", than: "1.0.0"))
    }

    func test_isNewer_returnsTrueForMinorBump() {
        XCTAssertTrue(VersionComparator.isNewer(version: "1.1.0", than: "1.0.9"))
    }

    func test_isNewer_returnsTrueForMajorBump() {
        XCTAssertTrue(VersionComparator.isNewer(version: "2.0.0", than: "1.99.99"))
    }

    func test_isNewer_returnsFalseForSameVersion() {
        XCTAssertFalse(VersionComparator.isNewer(version: "1.2.3", than: "1.2.3"))
    }

    func test_isNewer_returnsFalseForOlderVersion() {
        XCTAssertFalse(VersionComparator.isNewer(version: "1.0.0", than: "1.0.1"))
    }

    /// "1.0" should compare equal to "1.0.0" — the shorter version pads with
    /// implicit zero components.
    func test_isNewer_padsShorterVersionWithZeros() {
        XCTAssertFalse(VersionComparator.isNewer(version: "1.0", than: "1.0.0"))
        XCTAssertFalse(VersionComparator.isNewer(version: "1.0.0", than: "1.0"))
    }

    /// A longer version with a non-zero extra component must compare newer.
    func test_isNewer_treatsExtraNonZeroComponentAsNewer() {
        XCTAssertTrue(VersionComparator.isNewer(version: "1.0.0.1", than: "1.0.0"))
    }

    /// Build suffixes ("1.2.3-beta", "1.2.3+456") are tolerated — we strip
    /// non-digit trailing characters from each numeric component so the
    /// numeric prefix governs the comparison.
    func test_isNewer_tolerantOfNonDigitSuffixes() {
        XCTAssertTrue(VersionComparator.isNewer(version: "1.2.4-beta", than: "1.2.3"))
        XCTAssertFalse(VersionComparator.isNewer(version: "1.2.3-beta", than: "1.2.3"))
    }

    /// Numeric components larger than `Int.max` would crash a naive Int
    /// parse; the comparator falls back to lexicographic compare in that case
    /// without crashing.
    func test_isNewer_doesNotCrashOnHugeComponents() {
        XCTAssertNoThrow(VersionComparator.isNewer(
            version: "99999999999999999999.0",
            than: "1.0"
        ))
    }
}
