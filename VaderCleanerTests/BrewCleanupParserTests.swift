// BrewCleanupParserTests.swift
// Verifies parsing of `brew cleanup -n` reclaimable totals and `brew autoremove` removed-name lists.

import XCTest
@testable import VaderCleaner

final class BrewCleanupParserTests: XCTestCase {

    func test_parseCleanupDryRun_readsGigabyteTotal() {
        let stdout = """
        Would remove: /Users/x/Library/Caches/Homebrew/git--2.42.0 (12.3MB)
        ==> This operation would free approximately 2.5GB of disk space.
        """
        XCTAssertEqual(BrewOutputParser.parseCleanupDryRun(stdout), Int64((2.5 * 1_073_741_824).rounded()))
    }

    func test_parseCleanupDryRun_readsMegabyteTotal() {
        let stdout = "==> This operation would free approximately 512MB of disk space."
        XCTAssertEqual(BrewOutputParser.parseCleanupDryRun(stdout), 512 * 1_048_576)
    }

    func test_parseCleanupDryRun_nothingToDoIsNil() {
        XCTAssertNil(BrewOutputParser.parseCleanupDryRun(""))
        XCTAssertNil(BrewOutputParser.parseCleanupDryRun("Nothing to do."))
    }

    func test_parseCleanupDryRun_unparseableTotalIsNil() {
        // "would free" present but with no recognizable size token.
        XCTAssertNil(BrewOutputParser.parseCleanupDryRun("This operation would free some space."))
    }

    func test_firstByteSize_parsesUnits() {
        XCTAssertEqual(BrewOutputParser.firstByteSize(in: "900B"), 900)
        XCTAssertEqual(BrewOutputParser.firstByteSize(in: "1.5KB"), Int64((1.5 * 1024).rounded()))
        XCTAssertEqual(BrewOutputParser.firstByteSize(in: "cache (2GB) freed"), 2 * 1_073_741_824)
        XCTAssertNil(BrewOutputParser.firstByteSize(in: "no size here"))
    }

    func test_parseAutoremove_listsRemovedNames() {
        let stdout = """
        ==> Autoremoving 2 unneeded formulae:
        libyaml
        readline
        ==> Uninstalling /opt/homebrew/Cellar/libyaml/0.2.5
        """
        XCTAssertEqual(BrewOutputParser.parseAutoremove(stdout), ["libyaml", "readline"])
    }

    func test_parseAutoremove_noneReturnsEmpty() {
        XCTAssertTrue(BrewOutputParser.parseAutoremove("").isEmpty)
    }
}
