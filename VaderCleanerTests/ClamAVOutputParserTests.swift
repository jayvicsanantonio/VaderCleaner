// ClamAVOutputParserTests.swift
// Exercises ClamAVOutputParser against representative clamscan output: infected lines, clean scans, colon-bearing paths, and non-threat noise.

import Foundation
import Testing
@testable import VaderCleaner

@Suite
struct ClamAVOutputParserTests {

    @Test
    func parse_extractsPathAndThreatNameFromInfectedLines() {
        let output = """
        /Users/x/Downloads/evil.bin: Eicar-Test-Signature FOUND
        /Users/x/Library/Caches/bad.dmg: Osx.Trojan.Generic-1 FOUND
        """
        let threats = ClamAVOutputParser.parse(output)

        #expect(threats.count == 2)
        #expect(threats[0].filePath == URL(fileURLWithPath: "/Users/x/Downloads/evil.bin"))
        #expect(threats[0].threatName == "Eicar-Test-Signature")
        #expect(threats[1].filePath == URL(fileURLWithPath: "/Users/x/Library/Caches/bad.dmg"))
        #expect(threats[1].threatName == "Osx.Trojan.Generic-1")
    }

    @Test
    func parse_returnsEmptyForCleanScanOutput() {
        let output = """
        /Users/x/Documents/report.pdf: OK
        /Users/x/Documents/photo.jpg: OK
        """
        #expect(ClamAVOutputParser.parse(output).isEmpty)
    }

    @Test
    func parse_returnsEmptyForEmptyOutput() {
        #expect(ClamAVOutputParser.parse("").isEmpty)
        #expect(ClamAVOutputParser.parse("   \n  \n").isEmpty)
    }

    @Test
    func parse_handlesPathsContainingColons() {
        // The separator before the threat name is the LAST ": "; a colon in
        // the path itself must not split the file off prematurely.
        let output = "/Users/x/notes: meeting 3:30.txt: Eicar-Test-Signature FOUND"
        let threats = ClamAVOutputParser.parse(output)

        #expect(threats.count == 1)
        #expect(threats[0].filePath == URL(fileURLWithPath: "/Users/x/notes: meeting 3:30.txt"))
        #expect(threats[0].threatName == "Eicar-Test-Signature")
    }

    @Test
    func parseLine_returnsThreatForFoundLineAndNilOtherwise() {
        let threat = ClamAVOutputParser.parseLine(
            "/Users/x/evil.bin: Eicar-Test-Signature FOUND"
        )
        #expect(threat?.filePath == URL(fileURLWithPath: "/Users/x/evil.bin"))
        #expect(threat?.threatName == "Eicar-Test-Signature")

        #expect(ClamAVOutputParser.parseLine("/Users/x/a.txt: OK") == nil)
        #expect(ClamAVOutputParser.parseLine("/var/db/x: Access denied ERROR") == nil)
        #expect(ClamAVOutputParser.parseLine("Scanning /Users/x") == nil)
        #expect(ClamAVOutputParser.parseLine("") == nil)
    }

    @Test
    func parse_ignoresErrorAndSummaryLines() {
        let output = """
        /private/var/db/locked.db: Access denied ERROR
        /Users/x/Downloads/evil.bin: Eicar-Test-Signature FOUND
        ----------- SCAN SUMMARY -----------
        Infected files: 1
        """
        let threats = ClamAVOutputParser.parse(output)

        #expect(threats.count == 1)
        #expect(threats[0].threatName == "Eicar-Test-Signature")
    }
}
