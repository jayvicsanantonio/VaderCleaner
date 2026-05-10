// BrowserDataPathProviderTests.swift
// Verifies that DefaultBrowserDataPathProvider resolves the expected on-disk locations for each (Browser, PrivacyCategory) pair against an injected home directory, including Safari's legacy + container split and Firefox's randomized profile prefix.

import XCTest
@testable import VaderCleaner

final class BrowserDataPathProviderTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempHome)
        tempHome = nil
        try super.tearDownWithError()
    }

    // MARK: - Safari

    /// Safari's data lives in two places on modern macOS — the legacy paths
    /// under `~/Library/Safari` and the sandbox-container paths under
    /// `~/Library/Containers/com.apple.Safari/Data/Library/...`. Some users
    /// have both populated, so we emit *both* and let the clearer skip
    /// whichever doesn't exist on a given machine.
    func test_safari_history_includesLegacyAndContainerPaths() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .safari, category: .history)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Safari/History.db").path))
        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/History.db").path))
    }

    func test_safari_cookies_targetsBothLegacyAndContainerCookies() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .safari, category: .cookies)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Cookies/Cookies.binarycookies").path))
        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies").path))
    }

    func test_safari_cache_targetsBothLegacyAndContainerCaches() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .safari, category: .cache)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Caches/com.apple.Safari").path))
        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari").path))
    }

    // MARK: - Chrome

    /// Chromium browsers store everything for the default profile under
    /// `Application Support/<vendor>/<product>/Default/`. The provider must
    /// hit the right SQLite files for each category — typing one wrong leaves
    /// the user's history/cookies untouched while reporting it cleared.
    func test_chrome_history_targetsHistorySqliteUnderDefaultProfile() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .chrome, category: .history)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History").path))
    }

    func test_chrome_cookies_targetsCookiesSqliteUnderDefaultProfile() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .chrome, category: .cookies)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies").path))
    }

    /// Modern Chromium (since ~Chrome 96 / Edge 96) keeps the cookies
    /// SQLite under `Default/Network/Cookies`. Targeting only the legacy
    /// `Default/Cookies` location would silently skip cookies on every
    /// up-to-date install — the preview reports 0 B and "Clear" leaves
    /// the user's cookies intact while the UI claims success.
    func test_chrome_cookies_targetsNetworkCookiesSqliteUnderDefaultProfile() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .chrome, category: .cookies)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies").path))
    }

    /// SQLite `-wal` / `-shm` sidecars are present whenever the browser
    /// is or was recently running. Leaving them on disk after a clear
    /// undercounts the user's reclaimed space and leaves orphaned files
    /// the browser won't apply to a fresh DB.
    func test_chrome_history_includesSqliteWalAndShmSidecars() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .chrome, category: .history)
        let strings = paths.map { $0.path }

        let profile = tempHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        XCTAssertTrue(strings.contains(profile.appendingPathComponent("History-shm").path))
        XCTAssertTrue(strings.contains(profile.appendingPathComponent("History-wal").path))
    }

    /// Chromium and Firefox both store download history inside the same
    /// SQLite as browsing history, so a path-based "remove the file"
    /// clear of `.downloads` would also wipe browsing history when only
    /// `.downloads` is checked. The provider returns no paths for
    /// `.downloads` on these browsers — clearing them at the file level
    /// is only safe when the user also checks `.history`. The Privacy UI
    /// shows 0 B for the row so users see there's nothing to clear at
    /// the file level.
    func test_chrome_downloads_returnsEmptyToAvoidWipingHistory() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        XCTAssertEqual(provider.dataPaths(for: .chrome, category: .downloads), [])
        XCTAssertEqual(provider.dataPaths(for: .brave,  category: .downloads), [])
        XCTAssertEqual(provider.dataPaths(for: .arc,    category: .downloads), [])
        XCTAssertEqual(provider.dataPaths(for: .opera,  category: .downloads), [])
        XCTAssertEqual(provider.dataPaths(for: .edge,   category: .downloads), [])
    }

    func test_firefox_downloads_returnsEmptyToAvoidWipingPlacesSqlite() throws {
        let profilesRoot = tempHome.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        let profileDir = profilesRoot.appendingPathComponent("xyz12345.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        XCTAssertEqual(provider.dataPaths(for: .firefox, category: .downloads), [])
    }

    /// Safari's downloads live in a standalone `Downloads.plist`, so the
    /// constraint that forces Chromium/Firefox `.downloads` to return
    /// nothing doesn't apply — we *can* clear Safari's downloads
    /// independently.
    func test_safari_downloads_targetsDownloadsPlist() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .safari, category: .downloads)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Safari/Downloads.plist").path))
        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/Downloads.plist").path))
    }

    func test_chrome_cache_targetsCacheDirUnderCachesPath() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .chrome, category: .cache)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Caches/Google/Chrome").path))
    }

    func test_chrome_savedForms_targetsWebDataSqlite() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .chrome, category: .savedForms)
        let strings = paths.map { $0.path }

        XCTAssertTrue(strings.contains(tempHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Web Data").path))
    }

    // MARK: - Firefox

    /// Firefox profile dirs use a randomized 8-char prefix followed by
    /// `.default*`. The provider must enumerate `Profiles/` and surface the
    /// real profile dir's children — without that, every Firefox category
    /// would silently return zero on real machines.
    func test_firefox_history_resolvesAgainstActualProfileDirectory() throws {
        let profilesRoot = tempHome.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        let profileDir = profilesRoot.appendingPathComponent("xyz12345.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .firefox, category: .history)

        // `FileManager.contentsOfDirectory(at:)` returns URLs with a
        // `/private/var/...` prefix on macOS, while the test fixture's
        // URLs have a bare `/var/...` prefix (the firmlink). Both refer
        // to the same on-disk path; `(NSString) standardizingPath`
        // strips the `/private` prefix on both sides for comparison.
        let resolved = paths.map { Self.stripPrivatePrefix($0.path) }
        let expected = Self.stripPrivatePrefix(profileDir.appendingPathComponent("places.sqlite").path)
        XCTAssertTrue(resolved.contains(expected),
                      "Expected places.sqlite under \(profileDir.path), got \(resolved)")
    }

    func test_firefox_cache_resolvesAgainstCachesProfileDirectory() throws {
        let cacheProfilesRoot = tempHome.appendingPathComponent("Library/Caches/Firefox/Profiles", isDirectory: true)
        let cacheProfileDir = cacheProfilesRoot.appendingPathComponent("xyz12345.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheProfileDir, withIntermediateDirectories: true)

        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .firefox, category: .cache)

        let resolved = paths.map { Self.stripPrivatePrefix($0.path) }
        let expected = Self.stripPrivatePrefix(cacheProfileDir.appendingPathComponent("cache2").path)
        XCTAssertTrue(resolved.contains(expected),
                      "Expected cache2 under \(cacheProfileDir.path), got \(resolved)")
    }

    /// Same SQLite WAL/SHM concern as Chromium — Firefox uses WAL mode
    /// for places.sqlite and cookies.sqlite, so missing the `-shm` /
    /// `-wal` sidecars leaves orphaned files on disk.
    func test_firefox_history_includesSqliteWalAndShmSidecars() throws {
        let profilesRoot = tempHome.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        let profileDir = profilesRoot.appendingPathComponent("xyz12345.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let paths = provider.dataPaths(for: .firefox, category: .history)
        let resolved = paths.map { Self.stripPrivatePrefix($0.path) }

        let shm = Self.stripPrivatePrefix(profileDir.appendingPathComponent("places.sqlite-shm").path)
        let wal = Self.stripPrivatePrefix(profileDir.appendingPathComponent("places.sqlite-wal").path)
        XCTAssertTrue(resolved.contains(shm), "Expected places.sqlite-shm in \(resolved)")
        XCTAssertTrue(resolved.contains(wal), "Expected places.sqlite-wal in \(resolved)")
    }

    /// When no Firefox profile exists yet, the provider must return an
    /// empty array rather than path-guess at a non-existent profile dir —
    /// otherwise `previewSize` would always report 0 anyway, but `clear`
    /// would log misleading "missing path" debug messages on every machine
    /// without Firefox.
    func test_firefox_categories_returnEmptyWhenNoProfileExists() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        XCTAssertEqual(provider.dataPaths(for: .firefox, category: .history).count, 0)
        XCTAssertEqual(provider.dataPaths(for: .firefox, category: .cache).count, 0)
        XCTAssertEqual(provider.dataPaths(for: .firefox, category: .cookies).count, 0)
    }

    // MARK: - Other Chromium-based browsers

    /// Brave / Arc / Opera / Edge are all Chromium-based; the provider routes
    /// each to its vendor-specific Application Support root. Spot-check one
    /// per browser so a typo in the vendor-folder string surfaces in tests.
    func test_brave_chromiumPathsRouteToBraveSoftwareDirectory() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let history = provider.dataPaths(for: .brave, category: .history).map { $0.path }
        XCTAssertTrue(history.contains(tempHome.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default/History").path))
    }

    func test_edge_chromiumPathsRouteToMicrosoftEdgeDirectory() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let history = provider.dataPaths(for: .edge, category: .history).map { $0.path }
        XCTAssertTrue(history.contains(tempHome.appendingPathComponent("Library/Application Support/Microsoft Edge/Default/History").path))
    }

    func test_arc_chromiumPathsRouteToArcDirectory() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let history = provider.dataPaths(for: .arc, category: .history).map { $0.path }
        XCTAssertTrue(history.contains(tempHome.appendingPathComponent("Library/Application Support/Arc/User Data/Default/History").path))
    }

    /// `FileManager.contentsOfDirectory(at:)` returns URLs with a
    /// `/private/var/...` prefix on macOS while temp-dir fixtures have a
    /// bare `/var/...` prefix (firmlinked, not symlinked). Both refer to
    /// the same on-disk path. `(NSString) standardizingPath` only strips
    /// `/private` when the path resolves to an existing file, so we
    /// normalize ourselves for fixture paths that haven't been created.
    private static func stripPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    func test_opera_chromiumPathsRouteToOperaDirectory() {
        let provider = DefaultBrowserDataPathProvider(homeDirectory: tempHome)
        let history = provider.dataPaths(for: .opera, category: .history).map { $0.path }
        XCTAssertTrue(history.contains(tempHome.appendingPathComponent("Library/Application Support/com.operasoftware.Opera/History").path))
    }
}
