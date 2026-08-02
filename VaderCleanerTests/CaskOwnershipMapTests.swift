// CaskOwnershipMapTests.swift
// Tests matching a discovered .app bundle to the Homebrew cask that installed it — bundle-name and explicit-target matching, duplicate installs, and the Caskroom cross-check that names tokens brew's payload didn't describe.

import XCTest
@testable import VaderCleaner

final class CaskOwnershipMapTests: XCTestCase {

    // MARK: - Matching

    /// The common case: a cask names the bundle it installs and the app is
    /// found at the default location.
    func test_owner_matchesByBundleName() {
        let map = CaskOwnershipMap(casks: [
            CaskOwnership(token: "vlc", autoUpdates: true, appNames: ["VLC.app"])
        ])
        XCTAssertEqual(map.owner(of: app(at: "/Applications/VLC.app"))?.token, "vlc")
    }

    /// Bundle names are compared case-insensitively, matching the default
    /// case-insensitive macOS filesystem.
    func test_owner_matchesBundleNameCaseInsensitively() {
        let map = CaskOwnershipMap(casks: [
            CaskOwnership(token: "vlc", appNames: ["VLC.app"])
        ])
        XCTAssertEqual(map.owner(of: app(at: "/Applications/vlc.app"))?.token, "vlc")
    }

    /// A cask declaring an explicit `target` installs there, so that exact
    /// path is what establishes ownership.
    func test_owner_matchesByExplicitTarget() {
        let map = CaskOwnershipMap(casks: [
            CaskOwnership(
                token: "foo",
                appNames: ["Foo.app"],
                appTargets: [URL(fileURLWithPath: "/Applications/Bar.app")]
            )
        ])
        XCTAssertEqual(map.owner(of: app(at: "/Applications/Bar.app"))?.token, "foo")
    }

    /// Trailing-slash and `..` differences must not defeat the target
    /// match — paths are compared standardized.
    func test_owner_matchesTargetAcrossPathSpelling() {
        let map = CaskOwnershipMap(casks: [
            CaskOwnership(
                token: "foo",
                appTargets: [URL(fileURLWithPath: "/Applications/Utilities/../Bar.app")]
            )
        ])
        XCTAssertEqual(map.owner(of: app(at: "/Applications/Bar.app"))?.token, "foo")
    }

    /// A second copy of a cask-installed app elsewhere still reads as
    /// managed. The error is deliberate and one-sided: treating it as
    /// managed only costs a missed update offer, while treating it as
    /// unmanaged risks overwriting a Caskroom-tracked install.
    func test_owner_matchesCopyOutsideDefaultLocation() {
        let map = CaskOwnershipMap(casks: [
            CaskOwnership(token: "vlc", appNames: ["VLC.app"])
        ])
        let copy = app(at: NSHomeDirectory() + "/Applications/VLC.app")
        XCTAssertEqual(map.owner(of: copy)?.token, "vlc")
    }

    /// An app no cask mentions is not brew-managed.
    func test_owner_isNilForUnmanagedApp() {
        let map = CaskOwnershipMap(casks: [
            CaskOwnership(token: "vlc", appNames: ["VLC.app"])
        ])
        XCTAssertNil(map.owner(of: app(at: "/Applications/Telegram.app")))
    }

    /// A cask with no app artifacts (a CLI-only cask) owns no bundle.
    func test_owner_isNilWhenCaskInstallsNoApps() {
        let map = CaskOwnershipMap(casks: [CaskOwnership(token: "gcloud-cli")])
        XCTAssertNil(map.owner(of: app(at: "/Applications/gcloud.app")))
    }

    /// An empty map — brew absent, or its inventory unreadable — claims
    /// ownership of nothing.
    func test_owner_emptyMapOwnsNothing() {
        XCTAssertNil(CaskOwnershipMap().owner(of: app(at: "/Applications/VLC.app")))
    }

    // MARK: - Caskroom cross-check

    /// Tokens present in the Caskroom but absent from `brew info` are
    /// reported. Observed in practice as rename leftovers (`docker` after
    /// `docker-desktop`), so they are a diagnostic rather than proof the
    /// inventory is untrustworthy.
    func test_unresolvedTokens_namesCaskroomTokensMissingFromPayload() {
        let map = CaskOwnershipMap(
            casks: [CaskOwnership(token: "docker-desktop", appNames: ["Docker.app"])],
            caskroomTokens: ["docker-desktop", "docker", "windsurf"]
        )
        XCTAssertEqual(map.unresolvedTokens, ["docker", "windsurf"])
    }

    /// A fully explained Caskroom leaves nothing unresolved.
    func test_unresolvedTokens_isEmptyWhenPayloadExplainsEveryToken() {
        let map = CaskOwnershipMap(
            casks: [CaskOwnership(token: "vlc", appNames: ["VLC.app"])],
            caskroomTokens: ["vlc"]
        )
        XCTAssertTrue(map.unresolvedTokens.isEmpty)
    }

    /// Without a Caskroom listing there is nothing to cross-check, so no
    /// token is reported as unresolved.
    func test_unresolvedTokens_isEmptyWhenCaskroomNotListed() {
        let map = CaskOwnershipMap(casks: [CaskOwnership(token: "vlc")])
        XCTAssertTrue(map.unresolvedTokens.isEmpty)
    }

    /// An unresolved token does not itself claim ownership of an app —
    /// suppressing on a name guess would hide an app that Homebrew can no
    /// longer upgrade either, leaving nothing watching it.
    func test_owner_unresolvedTokenDoesNotClaimOwnership() {
        let map = CaskOwnershipMap(casks: [], caskroomTokens: ["windsurf"])
        XCTAssertNil(map.owner(of: app(at: "/Applications/Windsurf.app")))
    }

    // MARK: - Fixtures

    private func app(at path: String) -> AppInfo {
        AppInfo(
            name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            bundleID: "com.acme.fixture",
            version: "1.0",
            bundleURL: URL(fileURLWithPath: path),
            isAppStore: false
        )
    }
}
