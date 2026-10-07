// PathExclusionMatcherTests.swift
// Unit tests for the exclusion match contract every scanner shares, including the byte-level fast path in front of the Foundation comparison.

import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

/// `PathExclusionMatcher` decides, once per enumerated file, whether a path is
/// excluded. These drive it directly rather than through a walk — the matching
/// rules are pure string logic, and pinning them here keeps `FileScannerTests`
/// about what it says it is about: real directories on disk.
@Suite
struct PathExclusionMatcherTests {

    // `isExcluded` runs once per enumerated file per exclusion, so it carries a
    // byte-level fast path in front of the Foundation comparison. These pin the
    // matching contract directly, independent of any walk: the fast path may
    // only ever reject a pair the Foundation comparison would also reject.

    @Test
    func isExcluded_matchesTheExcludedPathItself() {
        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/foo", by: ["/tmp/foo"]))
    }

    @Test
    func isExcluded_matchesDescendantsOfAnExcludedPath() {
        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/foo/deep/file.bin", by: ["/tmp/foo"]))
    }

    @Test
    func isExcluded_stopsAtPathComponentBoundaries() {
        #expect(!PathExclusionMatcher.isExcluded(path: "/tmp/foobar/file.bin", by: ["/tmp/foo"]))
    }

    @Test
    func isExcluded_toleratesATrailingSlashOnTheExclusion() {
        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/foo/file.bin", by: ["/tmp/foo/"]))
    }

    @Test
    func isExcluded_isCaseInsensitiveForASCII() {
        #expect(PathExclusionMatcher.isExcluded(path: "/TMP/FOO/File.BIN", by: ["/tmp/foo"]))
        #expect(PathExclusionMatcher.isExcluded(path: "/TMP/FOO", by: ["/tmp/foo"]))
    }

    /// The case the byte-level fast path must not decide on its own: `É` and
    /// `é` are one Unicode case-folding apart but share no folded byte, so a
    /// naive ASCII comparison would reject a pair that genuinely matches on a
    /// case-insensitive volume.
    @Test
    func isExcluded_isCaseInsensitiveForNonASCII() {
        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/CAFÉ/file.bin", by: ["/tmp/café"]))
        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/CAFÉ", by: ["/tmp/café"]))
        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/naïve/Ünicode.txt", by: ["/tmp/NAÏVE"]))
    }

    @Test
    func isExcluded_rejectsANonMatchingUnicodePath() {
        #expect(!PathExclusionMatcher.isExcluded(path: "/tmp/café/file.bin", by: ["/tmp/cafe"]))
    }

    @Test
    func isExcluded_scansEveryExclusionInTheList() {
        let exclusions = ["/tmp/a", "/tmp/b", "/tmp/c"]

        #expect(PathExclusionMatcher.isExcluded(path: "/tmp/c/file.bin", by: exclusions))
        #expect(!PathExclusionMatcher.isExcluded(path: "/tmp/d/file.bin", by: exclusions))
    }

    @Test
    func isExcluded_withNoExclusionsMatchesNothing() {
        #expect(!PathExclusionMatcher.isExcluded(path: "/tmp/foo/file.bin", by: []))
    }

    /// A path shorter than the exclusion cannot sit beneath it, and the prefix
    /// scan must not read past the end of either buffer.
    @Test
    func isExcluded_withPathShorterThanTheExclusion() {
        #expect(!PathExclusionMatcher.isExcluded(path: "/tmp", by: ["/tmp/foo/bar"]))
        #expect(!PathExclusionMatcher.isExcluded(path: "", by: ["/tmp"]))
    }
}
