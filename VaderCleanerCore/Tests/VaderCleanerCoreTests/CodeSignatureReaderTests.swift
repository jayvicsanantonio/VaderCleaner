// CodeSignatureReaderTests.swift
// Tests the Security-framework signature read against bundles that exist on every macOS install, plus the unreadable cases that must degrade rather than trap.

import Foundation
import Testing
import XCTest
@testable import VaderCleanerCore

final class CodeSignatureReaderTests: XCTestCase {

    /// A system app is validly signed. This is the positive control: if
    /// it ever fails, the reader is broken rather than the app under
    /// test being unsigned.
    func test_signature_readsSystemAppAsValidlySigned() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: calculator.path),
            "Calculator.app is absent on this system"
        )
        let signature = CodeSignatureReader().signature(of: calculator)
        XCTAssertEqual(signature?.isValid, true)
    }

    /// Apple's own apps are signed by the platform authority and carry no
    /// Team ID. That is why `UpdateInstallGate` treats an absent team as
    /// "no continuity to prove" rather than as evidence of tampering —
    /// a validly signed app can legitimately have none.
    func test_signature_systemAppHasNoTeamIdentifier() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: calculator.path),
            "Calculator.app is absent on this system"
        )
        XCTAssertNil(CodeSignatureReader().signature(of: calculator)?.teamIdentifier)
    }

    /// A path with nothing at it reads as nil rather than trapping —
    /// discovery can race an app being removed.
    func test_signature_isNilForMissingBundle() {
        let missing = URL(fileURLWithPath: "/nonexistent/Nothing.app")
        XCTAssertNil(CodeSignatureReader().signature(of: missing))
    }

    /// A plain directory that isn't code reads as nil, not as a valid
    /// signature.
    func test_signature_isNilForNonCodeDirectory() throws {
        let temp = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(temp) }
        XCTAssertNil(CodeSignatureReader().signature(of: temp))
    }
}

private let systemCalculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

/// The check that makes a Team ID mean something. On its own the Team ID is
/// a field in the bundle's own signature, so it only counts once a
/// requirement anchored to Apple's CA confirms an Apple-issued certificate
/// for that team did the signing.
@Suite
struct CodeSignatureTeamRequirementTests {

    /// `anchor apple generic` is the clause a bare OU match lacks: without
    /// it a self-signed certificate whose leaf sets that OU satisfies the
    /// requirement.
    @Test
    func teamRequirement_anchorsTheTeamToApplesCA() {
        #expect(
            CodeSignatureReader.teamRequirement(for: "ABCDE12345")
                == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
        )
    }

    /// The Team ID is spliced into requirement-language source, so anything
    /// outside a Team ID's own alphabet is refused rather than escaped. The
    /// third case would otherwise widen the requirement to any trusted
    /// anchor at all.
    @Test(arguments: [
        "",
        "ABCDE 12345",
        #"ABCDE12345" or anchor trusted or certificate leaf[subject.OU] = "X"#,
        "ÄBCDE12345"
    ])
    func teamRequirement_refusesAnythingButATeamIdentifier(team: String) {
        #expect(CodeSignatureReader.teamRequirement(for: team) == nil)
    }

    /// Positive control. Without it, a reader that refused every
    /// requirement would pass every other test in this suite.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: systemCalculator.path)))
    func satisfies_acceptsARequirementTheBundleMeets() {
        #expect(CodeSignatureReader().satisfies(systemCalculator, requirement: "anchor apple"))
    }

    /// Calculator is validly signed and anchored to Apple, just not by that
    /// team — so this fails on the team clause specifically.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: systemCalculator.path)))
    func isSigned_refusesAValidBundleFromAnotherSigner() {
        #expect(!CodeSignatureReader().isSigned(systemCalculator, byTeam: "ABCDE12345"))
    }

    /// Requirement text that won't compile refuses rather than traps.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: systemCalculator.path)))
    func satisfies_refusesRequirementTextThatDoesNotParse() {
        #expect(!CodeSignatureReader().satisfies(systemCalculator, requirement: "anchor apple and ("))
    }

    @Test
    func satisfies_refusesAMissingBundle() {
        let missing = URL(fileURLWithPath: "/nonexistent/Nothing.app")
        #expect(!CodeSignatureReader().satisfies(missing, requirement: "anchor apple"))
    }
}
