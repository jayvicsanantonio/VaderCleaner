// ClamAVOutputParserTests.swift
// Exercises ClamAVOutputParser against representative clamscan output: infected lines, clean scans, colon-bearing paths, and non-threat noise.

import XCTest
@testable import VaderCleaner

final class ClamAVOutputParserTests: XCTestCase {

    func test_parse_extractsPathAndThreatNameFromInfectedLines() {
        let output = """
        /Users/x/Downloads/evil.bin: Eicar-Test-Signature FOUND
        /Users/x/Library/Caches/bad.dmg: Osx.Trojan.Generic-1 FOUND
        """
        let threats = ClamAVOutputParser.parse(output)

        XCTAssertEqual(threats.count, 2)
        XCTAssertEqual(threats[0].filePath, URL(fileURLWithPath: "/Users/x/Downloads/evil.bin"))
        XCTAssertEqual(threats[0].threatName, "Eicar-Test-Signature")
        XCTAssertEqual(threats[1].filePath, URL(fileURLWithPath: "/Users/x/Library/Caches/bad.dmg"))
        XCTAssertEqual(threats[1].threatName, "Osx.Trojan.Generic-1")
    }

    func test_parse_returnsEmptyForCleanScanOutput() {
        let output = """
        /Users/x/Documents/report.pdf: OK
        /Users/x/Documents/photo.jpg: OK
        """
        XCTAssertTrue(ClamAVOutputParser.parse(output).isEmpty)
    }

    func test_parse_returnsEmptyForEmptyOutput() {
        XCTAssertTrue(ClamAVOutputParser.parse("").isEmpty)
        XCTAssertTrue(ClamAVOutputParser.parse("   \n  \n").isEmpty)
    }

    func test_parse_handlesPathsContainingColons() {
        // The separator before the threat name is the LAST ": "; a colon in
        // the path itself must not split the file off prematurely.
        let output = "/Users/x/notes: meeting 3:30.txt: Eicar-Test-Signature FOUND"
        let threats = ClamAVOutputParser.parse(output)

        XCTAssertEqual(threats.count, 1)
        XCTAssertEqual(
            threats[0].filePath,
            URL(fileURLWithPath: "/Users/x/notes: meeting 3:30.txt")
        )
        XCTAssertEqual(threats[0].threatName, "Eicar-Test-Signature")
    }

    func test_parse_ignoresErrorAndSummaryLines() {
        let output = """
        /private/var/db/locked.db: Access denied ERROR
        /Users/x/Downloads/evil.bin: Eicar-Test-Signature FOUND
        ----------- SCAN SUMMARY -----------
        Infected files: 1
        """
        let threats = ClamAVOutputParser.parse(output)

        XCTAssertEqual(threats.count, 1)
        XCTAssertEqual(threats[0].threatName, "Eicar-Test-Signature")
    }
}
