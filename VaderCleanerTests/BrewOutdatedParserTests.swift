// BrewOutdatedParserTests.swift
// Verifies decoding of `brew outdated --json=v2` payloads: formulae, casks, pinned flags, empty, and malformed input.

import XCTest
@testable import VaderCleaner

final class BrewOutdatedParserTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_parseOutdated_formulaeOnly() throws {
        let json = """
        {
          "formulae": [
            {"name": "git", "installed_versions": ["2.42.0"], "current_version": "2.43.0", "pinned": false}
          ],
          "casks": []
        }
        """
        let items = try BrewOutputParser.parseOutdatedJSON(data(json))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "git")
        XCTAssertEqual(items[0].kind, .formula)
        XCTAssertEqual(items[0].installedVersion, "2.42.0")
        XCTAssertEqual(items[0].candidateVersion, "2.43.0")
        XCTAssertFalse(items[0].isPinned)
    }

    func test_parseOutdated_casksOnly_defaultUnpinned() throws {
        let json = """
        {
          "formulae": [],
          "casks": [
            {"name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0"}
          ]
        }
        """
        let items = try BrewOutputParser.parseOutdatedJSON(data(json))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .cask)
        XCTAssertEqual(items[0].candidateVersion, "121.0")
        XCTAssertFalse(items[0].isPinned)
    }

    func test_parseOutdated_mixedWithPinned() throws {
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
        XCTAssertEqual(items.count, 3)
        let node = items.first { $0.name == "node" }
        XCTAssertEqual(node?.isPinned, true)
        XCTAssertEqual(items.filter { $0.kind == .cask }.count, 1)
    }

    func test_parseOutdated_emptyPayload() throws {
        let items = try BrewOutputParser.parseOutdatedJSON(data(#"{"formulae": [], "casks": []}"#))
        XCTAssertTrue(items.isEmpty)
    }

    func test_parseOutdated_malformedThrows() {
        XCTAssertThrowsError(try BrewOutputParser.parseOutdatedJSON(data("not json")))
    }
}
