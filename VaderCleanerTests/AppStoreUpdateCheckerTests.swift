// AppStoreUpdateCheckerTests.swift
// Tests the iTunes Search API integration — JSON parsing for version and trackViewUrl, and graceful handling of empty result sets.

import XCTest
@testable import VaderCleaner

final class AppStoreUpdateCheckerTests: XCTestCase {

    /// On a successful lookup the checker returns the latest version and
    /// the App Store URL — both extracted from the iTunes Search response.
    func test_latestVersion_extractsVersionAndTrackViewURL() async throws {
        let payload = """
        {
          "resultCount": 1,
          "results": [
            {
              "version": "5.4.1",
              "trackViewUrl": "https://apps.apple.com/us/app/helio/id12345?mt=12",
              "bundleId": "com.acme.helio"
            }
          ]
        }
        """.data(using: .utf8)!

        let fetcher = StubHTTPFetcher()
        await fetcher.set(
            response: payload,
            for: URL(string: "https://itunes.apple.com/lookup?bundleId=com.acme.helio&entity=macSoftware")!
        )
        let checker = DefaultAppStoreUpdateChecker(httpFetcher: fetcher)
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertEqual(lookup?.version, "5.4.1")
        XCTAssertEqual(lookup?.appStoreURL,
                       URL(string: "https://apps.apple.com/us/app/helio/id12345?mt=12"))
    }

    /// An empty `results` array means the bundle ID isn't present in the
    /// store and the checker must return `nil` — not throw.
    func test_latestVersion_returnsNilForEmptyResults() async throws {
        let payload = #"{"resultCount":0,"results":[]}"#.data(using: .utf8)!
        let fetcher = StubHTTPFetcher()
        await fetcher.set(
            response: payload,
            for: URL(string: "https://itunes.apple.com/lookup?bundleId=com.acme.helio&entity=macSoftware")!
        )
        let checker = DefaultAppStoreUpdateChecker(httpFetcher: fetcher)
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertNil(lookup)
    }

    /// A non-200 response (rate limiting, 5xx, HTML error page) returns
    /// `nil` instead of surfacing as an opaque JSON decode failure.
    func test_latestVersion_nonOKStatusReturnsNil() async throws {
        let fetcher = StubHTTPFetcher()
        await fetcher.set(
            response: Data("Too Many Requests".utf8),
            for: URL(string: "https://itunes.apple.com/lookup?bundleId=com.acme.helio&entity=macSoftware")!,
            statusCode: 429
        )
        let checker = DefaultAppStoreUpdateChecker(httpFetcher: fetcher)
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertNil(lookup)
    }

    /// The lookup URL carries both `bundleId` and `entity=macSoftware`,
    /// the latter constraining results to Mac App Store titles so a
    /// same-bundle-ID iOS app can't shadow the macOS version. Bundle IDs
    /// in practice are reverse-DNS strings and don't carry characters
    /// that need percent-encoding, so we don't add a heavier escape pass
    /// on top of `URLQueryItem`.
    func test_latestVersion_buildsExpectedQueryURL() async throws {
        let fetcher = StubHTTPFetcher()
        let expected = URL(string: "https://itunes.apple.com/lookup?bundleId=com.acme.helio&entity=macSoftware")!
        await fetcher.set(
            response: #"{"resultCount":0,"results":[]}"#.data(using: .utf8)!,
            for: expected
        )
        let checker = DefaultAppStoreUpdateChecker(httpFetcher: fetcher)
        _ = try await checker.latestVersion(forBundleID: "com.acme.helio")
        let requested = await fetcher.requestedURLs
        XCTAssertEqual(requested.first, expected)
    }
}
