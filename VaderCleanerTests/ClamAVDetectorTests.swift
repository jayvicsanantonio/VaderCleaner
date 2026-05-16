// ClamAVDetectorTests.swift
// Verifies ClamAVDetector locates the clamscan binary across injected candidate paths and reports version via an injected runner.

import XCTest
@testable import VaderCleaner

final class ClamAVDetectorTests: XCTestCase {

    private let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")
    private let local = URL(fileURLWithPath: "/usr/local/bin/clamscan")

    func test_isInstalled_returnsBool_falseWhenNoCandidateIsExecutable() {
        let detector = ClamAVDetector(
            candidatePaths: [homebrew, local],
            isExecutable: { _ in false },
            versionRunner: { _ in nil }
        )
        XCTAssertFalse(detector.isInstalled())
    }

    func test_path_returnsFirstExecutableCandidate() {
        let detector = ClamAVDetector(
            candidatePaths: [homebrew, local],
            isExecutable: { $0 == self.local.path },
            versionRunner: { _ in nil }
        )
        XCTAssertEqual(detector.path(), local)
        XCTAssertTrue(detector.isInstalled())
    }

    func test_path_prefersEarlierCandidateWhenMultipleExecutable() {
        let detector = ClamAVDetector(
            candidatePaths: [homebrew, local],
            isExecutable: { _ in true },
            versionRunner: { _ in nil }
        )
        XCTAssertEqual(detector.path(), homebrew)
    }

    func test_path_isNilWhenNothingExecutable() {
        let detector = ClamAVDetector(
            candidatePaths: [homebrew, local],
            isExecutable: { _ in false },
            versionRunner: { _ in nil }
        )
        XCTAssertNil(detector.path())
    }

    func test_version_returnsTrimmedRunnerOutputWhenInstalled() async {
        let detector = ClamAVDetector(
            candidatePaths: [homebrew],
            isExecutable: { _ in true },
            versionRunner: { _ in "ClamAV 1.4.1/27000/Mon\n" }
        )
        let version = await detector.version()
        XCTAssertEqual(version, "ClamAV 1.4.1/27000/Mon")
    }

    func test_version_isNilWhenNotInstalled() async {
        let detector = ClamAVDetector(
            candidatePaths: [homebrew],
            isExecutable: { _ in false },
            versionRunner: { _ in "should not be called" }
        )
        let version = await detector.version()
        XCTAssertNil(version)
    }
}
