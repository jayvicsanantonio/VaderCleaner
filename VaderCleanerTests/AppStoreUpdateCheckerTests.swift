// AppStoreUpdateCheckerTests.swift
// Tests the iTunes Search API integration — JSON parsing for version and trackViewUrl, and graceful handling of empty result sets.

import XCTest
@testable import VaderCleaner

final class AppStoreUpdateCheckerTests: XCTestCase {

    /// On a successful lookup the checker returns the latest version and
    /// the App Store URL — both extracted from the iTunes Search response.
    func test_latestVersion_extractsVersionAndTrackViewURL() async throws {
        let payload = Data("""
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
        """.utf8)

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

    // MARK: - OS compatibility

    /// The iTunes response carries `minimumOsVersion`, and an app whose
    /// latest release needs a newer macOS than the user is running is not
    /// an available update — the App Store would refuse to install it.
    /// Mirrors the `sparkle:minimumSystemVersion` filter the Sparkle
    /// channel already applies.
    func test_latestVersion_returnsNilWhenLatestRequiresNewerMacOS() async throws {
        let checker = try await makeChecker(
            minimumOsVersion: "27.0",
            currentSystemVersion: "26.1.0"
        )
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertNil(lookup)
    }

    /// The running OS exactly meeting the minimum is supported — the
    /// comparison is `current >= minimum`, not a strict inequality.
    func test_latestVersion_allowsUpdateWhenSystemMeetsMinimumExactly() async throws {
        let checker = try await makeChecker(
            minimumOsVersion: "26.1",
            currentSystemVersion: "26.1.0"
        )
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertEqual(lookup?.version, "5.4.1")
    }

    /// A newer OS than required is obviously fine.
    func test_latestVersion_allowsUpdateWhenSystemExceedsMinimum() async throws {
        let checker = try await makeChecker(
            minimumOsVersion: "15.0",
            currentSystemVersion: "26.1.0"
        )
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertEqual(lookup?.version, "5.4.1")
    }

    /// An absent `minimumOsVersion` places no constraint. Dropping the
    /// update would suppress real ones, which is the worse error.
    func test_latestVersion_allowsUpdateWhenMinimumOsVersionAbsent() async throws {
        let checker = try await makeChecker(
            minimumOsVersion: nil,
            currentSystemVersion: "26.1.0"
        )
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertEqual(lookup?.version, "5.4.1")
    }

    /// An unparseable `minimumOsVersion` must not silently suppress a real
    /// update; it is treated as no constraint.
    func test_latestVersion_allowsUpdateWhenMinimumOsVersionIsUnparseable() async throws {
        let checker = try await makeChecker(
            minimumOsVersion: "",
            currentSystemVersion: "26.1.0"
        )
        let lookup = try await checker.latestVersion(forBundleID: "com.acme.helio")
        XCTAssertEqual(lookup?.version, "5.4.1")
    }

    // MARK: - Helpers

    /// Checker wired to a single canned lookup response for
    /// `com.acme.helio`, with the running macOS version injected so the
    /// compatibility filter is deterministic.
    private func makeChecker(
        minimumOsVersion: String?,
        currentSystemVersion: String
    ) async throws -> DefaultAppStoreUpdateChecker {
        let minimum = minimumOsVersion.map { "\"minimumOsVersion\":\"\($0)\"," } ?? ""
        let payload = Data("""
        {"resultCount":1,"results":[{
          \(minimum)
          "version":"5.4.1",
          "trackViewUrl":"https://apps.apple.com/us/app/helio/id12345?mt=12",
          "bundleId":"com.acme.helio"
        }]}
        """.utf8)
        let fetcher = StubHTTPFetcher()
        await fetcher.set(
            response: payload,
            for: URL(string: "https://itunes.apple.com/lookup?bundleId=com.acme.helio&entity=macSoftware")!
        )
        return DefaultAppStoreUpdateChecker(
            httpFetcher: fetcher,
            currentSystemVersion: currentSystemVersion
        )
    }

    /// An empty `results` array means the bundle ID isn't present in the
    /// store and the checker must return `nil` — not throw.
    func test_latestVersion_returnsNilForEmptyResults() async throws {
        let payload = Data(#"{"resultCount":0,"results":[]}"#.utf8)
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
            response: Data(#"{"resultCount":0,"results":[]}"#.utf8),
            for: expected
        )
        let checker = DefaultAppStoreUpdateChecker(httpFetcher: fetcher)
        _ = try await checker.latestVersion(forBundleID: "com.acme.helio")
        let requested = await fetcher.requestedURLs
        XCTAssertEqual(requested.first, expected)
    }
}
