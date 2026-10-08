// BrewCleanupParserTests.swift
// Verifies parsing of `brew cleanup -n` reclaimable totals and `brew autoremove` removed-name lists.

import Testing
@testable import VaderCleanerCore

@Suite
struct BrewCleanupParserTests {

    @Test
    func parseCleanupDryRun_readsGigabyteTotal() {
        let stdout = """
        Would remove: /Users/x/Library/Caches/Homebrew/git--2.42.0 (12.3MB)
        ==> This operation would free approximately 2.5GB of disk space.
        """
        #expect(BrewOutputParser.parseCleanupDryRun(stdout) == Int64((2.5 * 1_073_741_824).rounded()))
    }

    @Test
    func parseCleanupDryRun_readsMegabyteTotal() {
        let stdout = "==> This operation would free approximately 512MB of disk space."
        #expect(BrewOutputParser.parseCleanupDryRun(stdout) == Int64(512 * 1_048_576))
    }

    @Test
    func parseCleanupDryRun_nothingToDoIsNil() {
        #expect(BrewOutputParser.parseCleanupDryRun("") == nil)
        #expect(BrewOutputParser.parseCleanupDryRun("Nothing to do.") == nil)
    }

    @Test
    func parseCleanupDryRun_unparseableTotalIsNil() {
        // "would free" present but with no recognizable size token.
        #expect(BrewOutputParser.parseCleanupDryRun("This operation would free some space.") == nil)
    }

    @Test
    func firstByteSize_parsesUnits() {
        #expect(BrewOutputParser.firstByteSize(in: "900B") == 900)
        #expect(BrewOutputParser.firstByteSize(in: "1.5KB") == Int64((1.5 * 1024).rounded()))
        #expect(BrewOutputParser.firstByteSize(in: "cache (2GB) freed") == Int64(2 * 1_073_741_824))
        #expect(BrewOutputParser.firstByteSize(in: "no size here") == nil)
    }

    @Test
    func parseAutoremove_listsRemovedNames() {
        let stdout = """
        ==> Autoremoving 2 unneeded formulae:
        libyaml
        readline
        ==> Uninstalling /opt/homebrew/Cellar/libyaml/0.2.5
        """
        #expect(BrewOutputParser.parseAutoremove(stdout) == ["libyaml", "readline"])
    }

    @Test
    func parseAutoremove_noneReturnsEmpty() {
        #expect(BrewOutputParser.parseAutoremove("").isEmpty)
    }
}
