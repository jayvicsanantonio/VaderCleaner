// BrewOutputParserListTests.swift
// Verifies parsing of `brew list --versions`, `brew leaves`, and `brew uses --installed` output.

import Testing
@testable import VaderCleaner

@Suite
struct BrewOutputParserListTests {

    @Test
    func parseListVersions_singleAndMultiVersion() {
        let stdout = """
        git 2.43.0
        openssl@3 3.2.0 3.1.4
        """
        let packages = BrewOutputParser.parseListVersions(stdout, kind: .formula)
        #expect(packages.count == 2)
        #expect(packages[0].name == "git")
        #expect(packages[0].installedVersions == ["2.43.0"])
        #expect(packages[1].name == "openssl@3")
        #expect(packages[1].installedVersions == ["3.2.0", "3.1.4"])
        #expect(packages.allSatisfy { $0.kind == .formula })
    }

    @Test
    func parseListVersions_emptyOutputYieldsNoPackages() {
        #expect(BrewOutputParser.parseListVersions("", kind: .formula).isEmpty)
        #expect(BrewOutputParser.parseListVersions("\n\n", kind: .formula).isEmpty)
    }

    @Test
    func parseListVersions_marksLeavesForFormulae() {
        let stdout = """
        git 2.43.0
        readline 8.2
        """
        let packages = BrewOutputParser.parseListVersions(stdout, kind: .formula, leaves: ["git"])
        let git = packages.first { $0.name == "git" }
        let readline = packages.first { $0.name == "readline" }
        #expect(git?.isLeaf == true)
        #expect(readline?.isLeaf == false)
    }

    @Test
    func parseListVersions_casksAreAlwaysLeaves() {
        let stdout = "firefox 121.0"
        let packages = BrewOutputParser.parseListVersions(stdout, kind: .cask, leaves: [])
        #expect(packages.first?.isLeaf == true)
        #expect(packages.first?.kind == .cask)
    }

    @Test
    func parseLeaves_returnsNameSet() {
        let stdout = """
        git
        wget

        node
        """
        #expect(BrewOutputParser.parseLeaves(stdout) == ["git", "wget", "node"])
    }

    @Test
    func parseUses_withDependents() {
        let stdout = """
        curl
        wget
        """
        #expect(BrewOutputParser.parseUses(stdout) == ["curl", "wget"])
    }

    @Test
    func parseUses_withoutDependentsIsEmpty() {
        #expect(BrewOutputParser.parseUses("").isEmpty)
        #expect(BrewOutputParser.parseUses("\n").isEmpty)
    }
}
