// BrewCaskOwnershipParserTests.swift
// Fixture tests for parsing `brew info --json=v2 --installed` into cask→app ownership — the heterogeneous artifacts array, explicit targets, non-app artifacts, and the malformed shapes that must degrade rather than throw.

import Foundation
import Testing
@testable import VaderCleaner

@Suite
struct BrewCaskOwnershipParserTests {

    // MARK: - Artifacts

    /// The common shape: one cask installing one app bundle.
    @Test
    func parseInstalledCasks_readsSimpleAppArtifact() throws {
        let json = """
        {"casks":[{"token":"vlc","auto_updates":true,
          "artifacts":[{"app":["VLC.app"]}]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks.count == 1)
        #expect(casks[0].token == "vlc")
        #expect(casks[0].autoUpdates)
        #expect(casks[0].appNames == ["VLC.app"])
        #expect(casks[0].appTargets.isEmpty)
    }

    /// An `app` array can mix a bundle name with a dictionary naming an
    /// explicit install target. Both are ownership evidence and both must
    /// survive parsing.
    @Test
    func parseInstalledCasks_readsExplicitTargetAlongsideName() throws {
        let json = """
        {"casks":[{"token":"foo","auto_updates":false,
          "artifacts":[{"app":["Foo.app",{"target":"/Applications/Bar.app"}]}]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks[0].appNames == ["Foo.app"])
        #expect(casks[0].appTargets.map(\.path) == ["/Applications/Bar.app"])
    }

    /// A cask installs more than apps. Only `app` artifacts establish
    /// ownership of a discovered `.app` bundle; the rest are noise here.
    @Test
    func parseInstalledCasks_ignoresNonAppArtifacts() throws {
        let json = """
        {"casks":[{"token":"gcloud-cli","auto_updates":true,
          "artifacts":[{"binary":["bin/gcloud"]},{"pkg":["installer.pkg"]},
                       {"zap":[{"trash":["~/Library/Caches/gcloud"]}]}]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks.count == 1)
        #expect(casks[0].appNames.isEmpty)
        #expect(casks[0].appTargets.isEmpty)
    }

    /// Multiple apps from one cask (a suite) are all owned by it.
    @Test
    func parseInstalledCasks_readsMultipleAppArtifacts() throws {
        let json = """
        {"casks":[{"token":"suite","artifacts":[{"app":["One.app"]},{"app":["Two.app"]}]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks[0].appNames == ["One.app", "Two.app"])
    }

    // MARK: - Defaults and tolerance

    /// `auto_updates` is absent on most casks. It defaults to `false`,
    /// matching how `parseOutdatedJSON` already defaults `pinned`.
    @Test
    func parseInstalledCasks_autoUpdatesDefaultsToFalse() throws {
        let json = """
        {"casks":[{"token":"plain","artifacts":[{"app":["Plain.app"]}]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(!casks[0].autoUpdates)
    }

    /// A cask with no artifacts at all still yields an entry — the token is
    /// installed, we just learned nothing about which app it owns. Dropping
    /// it would silently narrow the ownership map.
    @Test
    func parseInstalledCasks_keepsCaskWithNoArtifacts() throws {
        let json = """
        {"casks":[{"token":"headless","auto_updates":false}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks.map(\.token) == ["headless"])
        #expect(casks[0].appNames.isEmpty)
    }

    /// Unrecognised shapes inside `artifacts` are skipped rather than
    /// thrown on — one odd cask definition must not blank the whole map,
    /// which is what would re-enable the clobber this parser prevents.
    @Test
    func parseInstalledCasks_skipsMalformedArtifactsWithoutThrowing() throws {
        let json = """
        {"casks":[{"token":"weird","artifacts":[
            "a bare string",
            {"app":"not-an-array"},
            {"app":[42, null]},
            {"app":["Good.app"]}
        ]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks[0].appNames == ["Good.app"])
    }

    /// A cask entry without a token cannot be acted on, so it is dropped.
    @Test
    func parseInstalledCasks_dropsCaskWithoutToken() throws {
        let json = """
        {"casks":[{"artifacts":[{"app":["Orphan.app"]}]},{"token":"real","artifacts":[]}]}
        """
        let casks = try BrewOutputParser.parseInstalledCasks(Data(json.utf8))
        #expect(casks.map(\.token) == ["real"])
    }

    /// The formulae-only payload from a machine with no casks yields an
    /// empty map, not an error.
    @Test
    func parseInstalledCasks_emptyCasksYieldsEmpty() throws {
        let json = #"{"formulae":[{"name":"jq"}],"casks":[]}"#
        #expect(try BrewOutputParser.parseInstalledCasks(Data(json.utf8)).isEmpty)
    }

    /// A missing `casks` key is treated as no casks — brew's payload shape
    /// has changed before and an absent key is not a parse failure.
    @Test
    func parseInstalledCasks_missingCasksKeyYieldsEmpty() throws {
        let json = #"{"formulae":[]}"#
        #expect(try BrewOutputParser.parseInstalledCasks(Data(json.utf8)).isEmpty)
    }

    /// Malformed JSON throws, so the caller reports a parse failure rather
    /// than silently concluding nothing is brew-managed — the conclusion
    /// that would permit a clobber.
    @Test
    func parseInstalledCasks_throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try BrewOutputParser.parseInstalledCasks(Data("not json".utf8))
        }
    }

    /// A JSON array at the root is well-formed JSON but the wrong shape,
    /// and must be reported rather than read as "no casks".
    @Test
    func parseInstalledCasks_throwsOnUnexpectedRootShape() {
        #expect(throws: (any Error).self) {
            try BrewOutputParser.parseInstalledCasks(Data("[]".utf8))
        }
    }
}
