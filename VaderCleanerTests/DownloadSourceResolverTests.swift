// DownloadSourceResolverTests.swift
// Pins the download-source resolution: bundle-id detection, and the installed-apps index matching an agent by bundle id, display name, or executable.

import XCTest
@testable import VaderCleaner

final class DownloadSourceResolverTests: XCTestCase {

    private func makeIndex() -> AppIndex {
        var index = AppIndex()
        let chrome = AppIndex.Ref(name: "Google Chrome", bundleID: "com.google.Chrome")
        let preview = AppIndex.Ref(name: "Preview", bundleID: "com.apple.Preview")
        index.byBundleID["com.google.chrome"] = chrome
        index.byName["google chrome"] = chrome
        index.byExecutable["google chrome"] = chrome
        index.byBundleID["com.apple.preview"] = preview
        index.byName["preview"] = preview
        return index
    }

    func test_isBundleIdentifier() {
        XCTAssertTrue(DownloadSourceResolver.isBundleIdentifier("com.google.Chrome"))
        XCTAssertTrue(DownloadSourceResolver.isBundleIdentifier("org.mozilla.firefox"))
        XCTAssertFalse(DownloadSourceResolver.isBundleIdentifier("Google Chrome"))
        XCTAssertFalse(DownloadSourceResolver.isBundleIdentifier("Preview"))
        XCTAssertFalse(DownloadSourceResolver.isBundleIdentifier("/Applications/Foo.app"))
    }

    func test_indexMatchesByName() {
        let ref = makeIndex().match(agent: "Preview")
        XCTAssertEqual(ref?.name, "Preview")
        XCTAssertEqual(ref?.bundleID, "com.apple.Preview")
    }

    func test_indexMatchesByBundleIDCaseInsensitive() {
        let ref = makeIndex().match(agent: "COM.GOOGLE.CHROME")
        XCTAssertEqual(ref?.name, "Google Chrome")
    }

    func test_indexReturnsNilForUnknownAgent() {
        XCTAssertNil(makeIndex().match(agent: "Totally Unknown App"))
    }

    func test_resolveFallsBackToCleanedAgentWhenUnmatched() {
        // A display-name agent with no matching installed app keeps its name.
        let resolved = DownloadSourceResolver.resolve(agent: "SomeUnknownApp", index: makeIndex())
        XCTAssertEqual(resolved.name, "SomeUnknownApp")
        XCTAssertNil(resolved.bundleID)
    }

    func test_resolveMatchesDisplayNameAgentFromIndex() {
        let resolved = DownloadSourceResolver.resolve(agent: "Preview", index: makeIndex())
        XCTAssertEqual(resolved.name, "Preview")
        XCTAssertEqual(resolved.bundleID, "com.apple.Preview")
    }

    func test_cleanStripsAppSuffix() {
        XCTAssertEqual(DownloadSourceResolver.clean("Foo.app"), "Foo")
        XCTAssertEqual(DownloadSourceResolver.clean("Bar"), "Bar")
    }

    func test_unescapeDecodesHexEscapes() {
        XCTAssertEqual(DownloadSourceResolver.unescape("Chrome\\x20Dev"), "Chrome Dev")
        XCTAssertEqual(DownloadSourceResolver.unescape("Google\\x20Chrome\\x20Dev"), "Google Chrome Dev")
        XCTAssertEqual(DownloadSourceResolver.unescape("Safari"), "Safari", "Strings without escapes pass through")
        XCTAssertEqual(DownloadSourceResolver.unescape("trailing\\x"), "trailing\\x", "A malformed escape is left as-is")
    }

    func test_knownBundleIDMapsChannelsAndApps() {
        XCTAssertEqual(DownloadSourceResolver.knownBundleID(for: "Chrome"), "com.google.Chrome")
        XCTAssertEqual(DownloadSourceResolver.knownBundleID(for: "Chrome Dev"), "com.google.Chrome.dev")
        XCTAssertEqual(DownloadSourceResolver.knownBundleID(for: "Safari"), "com.apple.Safari")
        XCTAssertEqual(DownloadSourceResolver.knownBundleID(for: "Firefox"), "org.mozilla.firefox")
        XCTAssertEqual(DownloadSourceResolver.knownBundleID(for: "Slack"), "com.tinyspeck.slackmacgap")
        XCTAssertNil(DownloadSourceResolver.knownBundleID(for: "Totally Unknown"))
    }

    func test_resolveDecodesAndAliasesChromeDev() {
        // The escaped agent decodes to "Chrome Dev" and aliases to the Chrome
        // Dev bundle id, so escaped and unescaped variants resolve identically.
        let escaped = DownloadSourceResolver.resolve(agent: "Chrome\\x20Dev", index: makeIndex())
        let plain = DownloadSourceResolver.resolve(agent: "Chrome Dev", index: makeIndex())
        XCTAssertEqual(escaped.bundleID, "com.google.Chrome.dev")
        XCTAssertEqual(plain.bundleID, "com.google.Chrome.dev")
    }
}
