// BrewOutdatedParserTests.swift
// Verifies decoding of `brew outdated --json=v2` payloads: formulae, casks, pinned flags, empty, and malformed input.

import Foundation
import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

@Suite
struct BrewOutdatedParserTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test
    func parseOutdated_formulaeOnly() throws {
        let json = """
        {
          "formulae": [
            {"name": "git", "installed_versions": ["2.42.0"], "current_version": "2.43.0", "pinned": false}
          ],
          "casks": []
        }
        """
        let items = try BrewOutputParser.parseOutdatedJSON(data(json))
        #expect(items.count == 1)
        #expect(items[0].name == "git")
        #expect(items[0].kind == .formula)
        #expect(items[0].installedVersion == "2.42.0")
        #expect(items[0].candidateVersion == "2.43.0")
        #expect(!items[0].isPinned)
    }

    @Test
    func parseOutdated_casksOnly_defaultUnpinned() throws {
        let json = """
        {
          "formulae": [],
          "casks": [
            {"name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0"}
          ]
        }
        """
        let items = try BrewOutputParser.parseOutdatedJSON(data(json))
        #expect(items.count == 1)
        #expect(items[0].kind == .cask)
        #expect(items[0].candidateVersion == "121.0")
        #expect(!items[0].isPinned)
    }

    @Test
    func parseOutdated_mixedWithPinned() throws {
        let json = """
        {
          "formulae": [
            {"name": "node", "installed_versions": ["20.0.0"], "current_version": "21.0.0", "pinned": true},
            {"name": "wget", "installed_versions": ["1.21"], "current_version": "1.22", "pinned": false}
          ],
          "casks": [
            {"name": "slack", "installed_versions": ["4.35"], "current_version": "4.36"}
          ]
        }
        """
        let items = try BrewOutputParser.parseOutdatedJSON(data(json))
        #expect(items.count == 3)
        let node = items.first { $0.name == "node" }
        #expect(node?.isPinned == true)
        #expect(items.filter { $0.kind == .cask }.count == 1)
    }

    @Test
    func parseOutdated_emptyPayload() throws {
        let items = try BrewOutputParser.parseOutdatedJSON(data(#"{"formulae": [], "casks": []}"#))
        #expect(items.isEmpty)
    }

    @Test
    func parseOutdated_malformedThrows() {
        #expect(throws: (any Error).self) {
            try BrewOutputParser.parseOutdatedJSON(data("not json"))
        }
    }
}
