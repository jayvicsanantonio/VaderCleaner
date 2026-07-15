// BrewOutputParserListTests.swift
// Verifies parsing of `brew list --versions`, `brew leaves`, and `brew uses --installed` output.

import XCTest
@testable import VaderCleaner

final class BrewOutputParserListTests: XCTestCase {

    func test_parseListVersions_singleAndMultiVersion() {
        let stdout = """
        git 2.43.0
        openssl@3 3.2.0 3.1.4
        """
        let packages = BrewOutputParser.parseListVersions(stdout, kind: .formula)
        XCTAssertEqual(packages.count, 2)
        XCTAssertEqual(packages[0].name, "git")
        XCTAssertEqual(packages[0].installedVersions, ["2.43.0"])
        XCTAssertEqual(packages[1].name, "openssl@3")
        XCTAssertEqual(packages[1].installedVersions, ["3.2.0", "3.1.4"])
        XCTAssertTrue(packages.allSatisfy { $0.kind == .formula })
    }

    func test_parseListVersions_emptyOutputYieldsNoPackages() {
        XCTAssertTrue(BrewOutputParser.parseListVersions("", kind: .formula).isEmpty)
        XCTAssertTrue(BrewOutputParser.parseListVersions("\n\n", kind: .formula).isEmpty)
    }

    func test_parseListVersions_marksLeavesForFormulae() {
        let stdout = """
        git 2.43.0
        readline 8.2
        """
        let packages = BrewOutputParser.parseListVersions(stdout, kind: .formula, leaves: ["git"])
        let git = packages.first { $0.name == "git" }
        let readline = packages.first { $0.name == "readline" }
        XCTAssertEqual(git?.isLeaf, true)
        XCTAssertEqual(readline?.isLeaf, false)
    }

    func test_parseListVersions_casksAreAlwaysLeaves() {
        let stdout = "firefox 121.0"
        let packages = BrewOutputParser.parseListVersions(stdout, kind: .cask, leaves: [])
        XCTAssertEqual(packages.first?.isLeaf, true)
        XCTAssertEqual(packages.first?.kind, .cask)
    }

    func test_parseLeaves_returnsNameSet() {
        let stdout = """
        git
        wget

        node
        """
        XCTAssertEqual(BrewOutputParser.parseLeaves(stdout), ["git", "wget", "node"])
    }

    func test_parseUses_withDependents() {
        let stdout = """
        curl
        wget
        """
        XCTAssertEqual(BrewOutputParser.parseUses(stdout), ["curl", "wget"])
    }

    func test_parseUses_withoutDependentsIsEmpty() {
        XCTAssertTrue(BrewOutputParser.parseUses("").isEmpty)
        XCTAssertTrue(BrewOutputParser.parseUses("\n").isEmpty)
    }
}
