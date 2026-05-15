// SparkleUpdateCheckerTests.swift
// Tests the Sparkle appcast pipeline — reading SUFeedURL from a fixture .app bundle, parsing appcast XML for the newest item, and routing the fetched bytes through the injected HTTPFetching seam.

import XCTest
@testable import VaderCleaner

final class SparkleUpdateCheckerTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempDirectory)
        tempDirectory = nil
    }

    // MARK: - feedURL

    /// `feedURL(for:)` reads the `SUFeedURL` value from the bundle's
    /// `Info.plist` — the standard Sparkle integration key.
    func test_feedURL_readsSUFeedURLFromInfoPlist() throws {
        let feed = "https://example.com/appcast.xml"
        let app = try makeAppBundle(
            name: "Helio",
            bundleID: "com.acme.helio",
            extraInfoPlist: ["SUFeedURL": feed]
        )
        let checker = DefaultSparkleUpdateChecker(httpFetcher: StubHTTPFetcher())
        XCTAssertEqual(checker.feedURL(for: app), URL(string: feed))
    }

    /// A bundle without `SUFeedURL` returns `nil`. The view-model uses this
    /// to skip Sparkle entirely for non-Sparkle apps.
    func test_feedURL_isNilWhenSUFeedURLMissing() throws {
        let app = try makeAppBundle(
            name: "Helio",
            bundleID: "com.acme.helio",
            extraInfoPlist: [:]
        )
        let checker = DefaultSparkleUpdateChecker(httpFetcher: StubHTTPFetcher())
        XCTAssertNil(checker.feedURL(for: app))
    }

    // MARK: - parseAppcast

    /// `parseAppcast(xml:)` picks the *newest* item by version, not by
    /// document order — real Sparkle appcasts emit items in non-monotonic
    /// order and our checker must not regress users by reporting a stale
    /// version as "the update".
    func test_parseAppcast_returnsNewestItemEvenWhenOutOfOrder() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>2.0.0</title>
              <enclosure url="https://example.com/Helio-2.0.0.dmg"
                         sparkle:version="2.0.0"
                         sparkle:shortVersionString="2.0.0" />
            </item>
            <item>
              <title>1.5.0</title>
              <enclosure url="https://example.com/Helio-1.5.0.dmg"
                         sparkle:version="1.5.0"
                         sparkle:shortVersionString="1.5.0" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let item = DefaultSparkleUpdateChecker.parseAppcast(xml: xml)
        XCTAssertEqual(item?.shortVersion, "2.0.0")
        XCTAssertEqual(item?.downloadURL, URL(string: "https://example.com/Helio-2.0.0.dmg"))
    }

    /// Items without an enclosure are skipped; release notes-only items are
    /// not actionable as an update target.
    func test_parseAppcast_skipsItemsWithoutEnclosure() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>2.0.0 notes</title>
              <sparkle:releaseNotesLink>https://example.com/notes.html</sparkle:releaseNotesLink>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        XCTAssertNil(DefaultSparkleUpdateChecker.parseAppcast(xml: xml))
    }

    /// When two items share the same `shortVersionString`, the one with
    /// the newer `sparkle:version` (build) must win so a same-marketing-
    /// version hotfix isn't passed over for an older artifact.
    func test_parseAppcast_tieBreaksOnBuildVersion() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure url="https://example.com/Helio-2.0.0-100.dmg"
                         sparkle:version="100"
                         sparkle:shortVersionString="2.0.0" />
            </item>
            <item>
              <enclosure url="https://example.com/Helio-2.0.0-105.dmg"
                         sparkle:version="105"
                         sparkle:shortVersionString="2.0.0" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let item = DefaultSparkleUpdateChecker.parseAppcast(xml: xml)
        XCTAssertEqual(item?.version, "105")
        XCTAssertEqual(item?.downloadURL,
                       URL(string: "https://example.com/Helio-2.0.0-105.dmg"))
    }

    /// Older feeds carry `sparkle:shortVersionString` / `sparkle:version`
    /// on the `<item>` element itself rather than the enclosure. The
    /// parser must still surface those rather than dropping the item.
    func test_parseAppcast_readsVersionAttributesOnItemElement() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item sparkle:shortVersionString="4.2.0" sparkle:version="4200">
              <enclosure url="https://example.com/Helio-4.2.0.dmg" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let item = DefaultSparkleUpdateChecker.parseAppcast(xml: xml)
        XCTAssertEqual(item?.shortVersion, "4.2.0")
        XCTAssertEqual(item?.downloadURL,
                       URL(string: "https://example.com/Helio-4.2.0.dmg"))
    }

    /// The newest item requires a macOS the user isn't running, so the
    /// parser must fall back to the newest *compatible* item rather than
    /// offering a build Sparkle itself would refuse to install.
    func test_parseAppcast_skipsItemsRequiringNewerMacOS() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:minimumSystemVersion>99.0.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/Helio-3.0.0.dmg"
                         sparkle:shortVersionString="3.0.0" sparkle:version="3000" />
            </item>
            <item>
              <sparkle:minimumSystemVersion>12.0.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/Helio-2.0.0.dmg"
                         sparkle:shortVersionString="2.0.0" sparkle:version="2000" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let item = DefaultSparkleUpdateChecker.parseAppcast(
            xml: xml,
            currentSystemVersion: "14.5.0"
        )
        XCTAssertEqual(item?.shortVersion, "2.0.0")
        XCTAssertEqual(item?.downloadURL,
                       URL(string: "https://example.com/Helio-2.0.0.dmg"))
    }

    /// An item is eligible exactly when the running OS meets its
    /// `minimumSystemVersion`; equal versions are eligible.
    func test_parseAppcast_includesItemWhenOSMeetsMinimum() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:minimumSystemVersion>14.5.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/Helio-5.0.0.dmg"
                         sparkle:shortVersionString="5.0.0" sparkle:version="5000" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let item = DefaultSparkleUpdateChecker.parseAppcast(
            xml: xml,
            currentSystemVersion: "14.5.0"
        )
        XCTAssertEqual(item?.shortVersion, "5.0.0")
    }

    // MARK: - fetchAppcast

    /// `fetchAppcast` runs feed bytes through the injected HTTP fetcher
    /// and returns the newest item — no live network access.
    func test_fetchAppcast_routesThroughInjectedFetcher() async throws {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item>
            <enclosure url="https://example.com/x.dmg"
                       sparkle:shortVersionString="3.0.0"
                       sparkle:version="3000" />
          </item></channel>
        </rss>
        """.data(using: .utf8)!

        let stub = StubHTTPFetcher()
        await stub.set(response: xml, for: URL(string: "https://example.com/appcast.xml")!)
        let checker = DefaultSparkleUpdateChecker(httpFetcher: stub)
        let item = try await checker.fetchAppcast(feedURL: URL(string: "https://example.com/appcast.xml")!)
        XCTAssertEqual(item?.shortVersion, "3.0.0")
    }

    /// A non-200 feed response (404/5xx/HTML error page) yields `nil`
    /// rather than attempting to parse an error body into a bogus item.
    func test_fetchAppcast_nonOKStatusReturnsNil() async throws {
        let stub = StubHTTPFetcher()
        await stub.set(
            response: Data("<html>not found</html>".utf8),
            for: URL(string: "https://example.com/appcast.xml")!,
            statusCode: 404
        )
        let checker = DefaultSparkleUpdateChecker(httpFetcher: stub)
        let item = try await checker.fetchAppcast(
            feedURL: URL(string: "https://example.com/appcast.xml")!
        )
        XCTAssertNil(item)
    }

    // MARK: - Helpers

    private func makeAppBundle(
        name: String,
        bundleID: String,
        extraInfoPlist: [String: Any]
    ) throws -> AppInfo {
        let appURL = tempDirectory
            .appendingPathComponent("\(name).app", isDirectory: true)
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
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
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

/// In-memory stand-in for `URLSession` used by both the Sparkle and App
/// Store checker tests so unit tests never touch the network.
actor StubHTTPFetcher: HTTPFetching {
    private var responses: [URL: (Data, URLResponse)] = [:]
    private(set) var requestedURLs: [URL] = []

    func set(response: Data, for url: URL, statusCode: Int = 200) {
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        responses[url] = (response, httpResponse)
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        if let pair = responses[url] {
            return pair
        }
        throw URLError(.fileDoesNotExist)
    }
}
