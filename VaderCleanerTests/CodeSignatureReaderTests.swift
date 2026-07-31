// CodeSignatureReaderTests.swift
// Tests the Security-framework signature read against bundles that exist on every macOS install, plus the unreadable cases that must degrade rather than trap.

import XCTest
@testable import VaderCleaner

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
