// PathExclusionMatcherTests.swift
// Unit tests for the exclusion match contract every scanner shares, including the byte-level fast path in front of the Foundation comparison.

import XCTest
@testable import VaderCleaner

/// `PathExclusionMatcher` decides, once per enumerated file, whether a path is
/// excluded. These drive it directly rather than through a walk — the matching
/// rules are pure string logic, and pinning them here keeps `FileScannerTests`
/// about what it says it is about: real directories on disk.
final class PathExclusionMatcherTests: XCTestCase {

    // `isExcluded` runs once per enumerated file per exclusion, so it carries a
    // byte-level fast path in front of the Foundation comparison. These pin the
    // matching contract directly, independent of any walk: the fast path may
    // only ever reject a pair the Foundation comparison would also reject.

    func test_isExcluded_matchesTheExcludedPathItself() {
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/foo", by: ["/tmp/foo"]))
    }

    func test_isExcluded_matchesDescendantsOfAnExcludedPath() {
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/foo/deep/file.bin", by: ["/tmp/foo"]))
    }

    func test_isExcluded_stopsAtPathComponentBoundaries() {
        XCTAssertFalse(PathExclusionMatcher.isExcluded(path: "/tmp/foobar/file.bin", by: ["/tmp/foo"]))
    }

    func test_isExcluded_toleratesATrailingSlashOnTheExclusion() {
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/foo/file.bin", by: ["/tmp/foo/"]))
    }

    func test_isExcluded_isCaseInsensitiveForASCII() {
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/TMP/FOO/File.BIN", by: ["/tmp/foo"]))
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/TMP/FOO", by: ["/tmp/foo"]))
    }

    /// The case the byte-level fast path must not decide on its own: `É` and
    /// `é` are one Unicode case-folding apart but share no folded byte, so a
    /// naive ASCII comparison would reject a pair that genuinely matches on a
    /// case-insensitive volume.
    func test_isExcluded_isCaseInsensitiveForNonASCII() {
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/CAFÉ/file.bin", by: ["/tmp/café"]))
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/CAFÉ", by: ["/tmp/café"]))
        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/naïve/Ünicode.txt", by: ["/tmp/NAÏVE"]))
    }

    func test_isExcluded_rejectsANonMatchingUnicodePath() {
        XCTAssertFalse(PathExclusionMatcher.isExcluded(path: "/tmp/café/file.bin", by: ["/tmp/cafe"]))
    }

    func test_isExcluded_scansEveryExclusionInTheList() {
        let exclusions = ["/tmp/a", "/tmp/b", "/tmp/c"]

        XCTAssertTrue(PathExclusionMatcher.isExcluded(path: "/tmp/c/file.bin", by: exclusions))
        XCTAssertFalse(PathExclusionMatcher.isExcluded(path: "/tmp/d/file.bin", by: exclusions))
    }

    func test_isExcluded_withNoExclusionsMatchesNothing() {
        XCTAssertFalse(PathExclusionMatcher.isExcluded(path: "/tmp/foo/file.bin", by: []))
    }

    /// A path shorter than the exclusion cannot sit beneath it, and the prefix
    /// scan must not read past the end of either buffer.
    func test_isExcluded_withPathShorterThanTheExclusion() {
        XCTAssertFalse(PathExclusionMatcher.isExcluded(path: "/tmp", by: ["/tmp/foo/bar"]))
        XCTAssertFalse(PathExclusionMatcher.isExcluded(path: "", by: ["/tmp"]))
    }
}
