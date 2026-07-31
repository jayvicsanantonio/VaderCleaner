// SparkleSigningInputsTests.swift
// Tests the two inputs UpdateInstallGate needs from the Sparkle channel — the enclosure's Ed25519 signature and the SUPublicEDKey the installed bundle advertises — including the legacy DSA-only feeds that yield neither.

import XCTest
@testable import VaderCleaner

final class SparkleSigningInputsTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempDirectory)
        tempDirectory = nil
    }

    // MARK: - Signing inputs

    /// The enclosure's `sparkle:edSignature` is what `UpdateInstallGate`
    /// checks a download against, so it must survive parsing.
    func test_parseAppcast_readsEdSignatureFromEnclosure() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure url="https://example.com/Helio-2.0.0.zip"
                         sparkle:shortVersionString="2.0.0"
                         sparkle:edSignature="c2lnbmF0dXJlLWJ5dGVz"/>
            </item>
          </channel>
        </rss>
        """.utf8)
        let item = DefaultSparkleUpdateChecker.parseAppcast(xml: xml, currentSystemVersion: "26.0.0")
        XCTAssertEqual(item?.edSignature, "c2lnbmF0dXJlLWJ5dGVz")
    }

    /// A Sparkle 1 feed publishes only `sparkle:dsaSignature`. It parses
    /// to a nil `edSignature`, which the gate reads as unverifiable —
    /// not as an attack, and not as permission to install.
    func test_parseAppcast_legacyDSAOnlyFeedHasNoEdSignature() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure url="https://example.com/Helio-2.0.0.zip"
                         sparkle:shortVersionString="2.0.0"
                         sparkle:dsaSignature="MCwCFC41j4MqZmvu2BytSE3tUUDuKxC8"/>
            </item>
          </channel>
        </rss>
        """.utf8)
        let item = DefaultSparkleUpdateChecker.parseAppcast(xml: xml, currentSystemVersion: "26.0.0")
        XCTAssertNotNil(item)
        XCTAssertNil(item?.edSignature)
    }

    /// `publicEDKey(for:)` reads the key from the installed bundle, never
    /// from the feed — a hijacked appcast must not be able to supply the
    /// key its own signature verifies against.
    func test_publicEDKey_readsSUPublicEDKeyFromInstalledBundle() throws {
        let app = try makeAppBundle(
            name: "Helio",
            bundleID: "com.acme.helio",
            extraInfoPlist: ["SUPublicEDKey": "cHVibGljLWtleS1ieXRlcw=="]
        )
        let checker = DefaultSparkleUpdateChecker(httpFetcher: StubHTTPFetcher())
        XCTAssertEqual(checker.publicEDKey(for: app), "cHVibGljLWtleS1ieXRlcw==")
    }

    /// A bundle without the key, or with an empty one, yields nil so the
    /// gate reports unverifiable rather than comparing against nothing.
    func test_publicEDKey_isNilWhenAbsentOrEmpty() throws {
        let checker = DefaultSparkleUpdateChecker(httpFetcher: StubHTTPFetcher())
        for plist in [[:], ["SUPublicEDKey": ""]] as [[String: Any]] {
            let app = try makeAppBundle(
                name: "Bare\(plist.count)",
                bundleID: "com.acme.bare\(plist.count)",
                extraInfoPlist: plist
            )
            XCTAssertNil(checker.publicEDKey(for: app))
        }
    }

    // MARK: - Helpers

    private func makeAppBundle(
        name: String,
        bundleID: String,
        extraInfoPlist: [String: Any]
    ) throws -> AppInfo {
        let appURL = tempDirectory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleShortVersionString": "1.0"
        ]
        for (key, value) in extraInfoPlist {
            plist[key] = value
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: appURL,
            isAppStore: false
        )
    }
}
