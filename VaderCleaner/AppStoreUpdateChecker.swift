// AppStoreUpdateChecker.swift
// Mac App Store update lookup via the public iTunes Search API — returns the latest released version and the apps.apple.com URL for an installed App Store bundle ID.

import Foundation

/// Reduced view of the iTunes Search API response that the App Updater
/// actually consumes — version and the App Store URL we hand to
/// `NSWorkspace.open`.
struct AppStoreLookup: Hashable, Sendable {
    let version: String
    let appStoreURL: URL
}

/// Production implementation. Returns `nil` on empty result sets rather
/// than throwing — many MAS apps don't surface in the lookup API and a
/// missing entry is not an error from the App Updater's perspective.
struct DefaultAppStoreUpdateChecker: Sendable {

    private let httpFetcher: HTTPFetching
    private let baseURL: URL
    private let currentSystemVersion: String

    /// - Parameter currentSystemVersion: the running macOS product
    ///   version ("26.1.0"), used to drop releases this Mac cannot
    ///   install. Injected by tests so the filter is deterministic.
    init(
        httpFetcher: HTTPFetching = URLSession.shared,
        baseURL: URL = URL(string: "https://itunes.apple.com/lookup")!,
        currentSystemVersion: String = DefaultSparkleUpdateChecker.currentSystemVersionString()
    ) {
        self.httpFetcher = httpFetcher
        self.baseURL = baseURL
        self.currentSystemVersion = currentSystemVersion
    }

    func latestVersion(forBundleID bundleID: String) async throws -> AppStoreLookup? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // `URLQueryItem` percent-encodes the value, so a bundle ID
        // containing `+` (rare but legal) round-trips correctly through
        // the query string. `entity=macSoftware` constrains the lookup to
        // Mac App Store titles — a bundle ID can in principle match an
        // iOS app with the same identifier, and we only ever want the
        // macOS build's version here.
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "macSoftware")
        ]
        guard let url = components.url else { return nil }

        let (data, response) = try await httpFetcher.data(from: url)
        // A non-200 (rate limiting, 5xx, an HTML error page) would only
        // surface as an opaque JSON decoding failure further down. Treat
        // it the same as "no result" — the caller already tolerates a
        // nil lookup as "no update info available".
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        let payload = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let first = payload.results.first,
              let storeURL = URL(string: first.trackViewUrl) else {
            return nil
        }
        // The lookup reports the latest release worldwide, which may
        // require a newer macOS than this Mac runs. Offering it would
        // produce an update row the App Store then refuses to install.
        // The Sparkle channel already filters on
        // `sparkle:minimumSystemVersion`; this is the same rule.
        guard supportsCurrentSystem(minimum: first.minimumOsVersion) else {
            return nil
        }
        return AppStoreLookup(version: first.version, appStoreURL: storeURL)
    }

    /// Whether the running macOS satisfies `minimum`. An absent or
    /// unparseable value places no constraint — suppressing a real update
    /// on a value we failed to read is the worse error.
    private func supportsCurrentSystem(minimum: String?) -> Bool {
        guard let minimum, !minimum.isEmpty else { return true }
        return VersionComparator.compare(currentSystemVersion, minimum) != .orderedAscending
    }

    private struct LookupResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String
            /// Absent on some entries, so optional rather than defaulted.
            let minimumOsVersion: String?
        }
    }
}
