// BrowserPrivacyProfilesTests.swift
// Pins that privacy data is read and removed across every browser profile, that removal leaves no linked rows and reports what it couldn't do, and that a category the app can't read says so instead of showing zero.

import Foundation
import SQLite3
import Testing
@testable import VaderCleanerCore

private struct StubPaths: BrowserDataPathProviding {
    let paths: [PrivacyCategory: [URL]]
    func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
        paths[category] ?? []
    }
}

/// A temp directory with helpers to seed and read small SQLite stores.
private struct Stores {
    let root: URL

    init() throws {
        root = try TestHelpers.createTempDirectory()
    }

    func url(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func seed(_ url: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    func count(_ url: URL, _ table: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \"\(table)\"", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
        return Int(sqlite3_column_int64(statement, 0))
    }

    func remover(_ paths: [PrivacyCategory: [URL]]) -> BrowserPrivacyRemover {
        BrowserPrivacyRemover(pathProvider: StubPaths(paths: paths), isBrowserRunning: { _ in false })
    }

    func inspector(_ paths: [PrivacyCategory: [URL]]) -> BrowserPrivacyInspector {
        BrowserPrivacyInspector(pathProvider: StubPaths(paths: paths))
    }
}

private let chromiumDownloads = """
    CREATE TABLE downloads (id INTEGER PRIMARY KEY, tab_url TEXT);
    CREATE TABLE downloads_url_chains (id INTEGER, chain_index INTEGER, url TEXT);
    CREATE TABLE downloads_slices (download_id INTEGER, offset INTEGER);
    CREATE TABLE downloads_reroute_info (download_id INTEGER, data TEXT);
    INSERT INTO downloads VALUES (1, 'https://a.com/page'), (2, 'https://b.com/page');
    INSERT INTO downloads_url_chains VALUES (1, 0, 'https://a.com/secret.dmg'), (2, 0, 'https://b.com/keep.dmg');
    INSERT INTO downloads_slices VALUES (1, 0), (2, 0);
    INSERT INTO downloads_reroute_info VALUES (1, 'x'), (2, 'y');
    """

@Suite
struct BrowserPrivacyRemoverCompletenessTests {

    @Test
    func removingAllDownloadsLeavesNoURLBehind() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let history = stores.url("History")
        try stores.seed(history, chromiumDownloads)

        try await stores.remover([.history: [history]]).remove([
            PrivacyRemovalRequest(browser: .chrome, category: .downloadsHistory, scope: .wholeCategory)
        ])

        #expect(try stores.count(history, "downloads") == 0)
        #expect(try stores.count(history, "downloads_url_chains") == 0, "this table holds the actual download URL")
        #expect(try stores.count(history, "downloads_slices") == 0)
        #expect(try stores.count(history, "downloads_reroute_info") == 0)
    }

    @Test
    func removingOneSitesDownloadsTakesOnlyItsLinkedRows() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let history = stores.url("History")
        try stores.seed(history, chromiumDownloads)

        try await stores.remover([.history: [history]]).remove([
            PrivacyRemovalRequest(browser: .chrome, category: .downloadsHistory, scope: .items(hostKeys: ["a.com"]))
        ])

        #expect(try stores.count(history, "downloads") == 1)
        #expect(try stores.count(history, "downloads_url_chains") == 1)
        #expect(try stores.count(history, "downloads_slices") == 1)
        #expect(try stores.count(history, "downloads_reroute_info") == 1)
    }

    @Test
    func anOlderSchemaWithoutTheLinkedTablesStillRemovesDownloads() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let history = stores.url("History")
        try stores.seed(history, """
            CREATE TABLE downloads (id INTEGER PRIMARY KEY, tab_url TEXT);
            INSERT INTO downloads VALUES (1, 'https://a.com/page');
            """)

        try await stores.remover([.history: [history]]).remove([
            PrivacyRemovalRequest(browser: .chrome, category: .downloadsHistory, scope: .wholeCategory)
        ])

        #expect(try stores.count(history, "downloads") == 0)
    }

    @Test
    func aSiteIsRemovedFromEveryProfile() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let first = stores.url("Default/Cookies")
        let second = stores.url("Profile 1/Cookies")
        for store in [first, second] {
            try stores.seed(store, """
                CREATE TABLE cookies (host_key TEXT);
                INSERT INTO cookies VALUES ('.a.com'), ('.b.com');
                """)
        }

        try await stores.remover([.cookies: [first, second]]).remove([
            PrivacyRemovalRequest(browser: .chrome, category: .cookies, scope: .items(hostKeys: [".a.com"]))
        ])

        #expect(try stores.count(first, "cookies") == 1)
        #expect(try stores.count(second, "cookies") == 1)
    }

    @Test
    func aStoreThatCannotBeWrittenIsReportedAndTheRestStillGo() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let locked = stores.url("Cookies")
        try stores.seed(locked, """
            CREATE TABLE cookies (host_key TEXT);
            INSERT INTO cookies VALUES ('.a.com');
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let cache = stores.url("Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        await #expect(throws: PrivacyRemovalError.incomplete) {
            try await stores.remover([.cookies: [locked], .cache: [cache]]).remove([
                PrivacyRemovalRequest(browser: .chrome, category: .cookies, scope: .wholeCategory),
                PrivacyRemovalRequest(browser: .chrome, category: .cachedFiles, scope: .wholeCategory)
            ])
        }

        #expect(try stores.count(locked, "cookies") == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.path), "one failure doesn't stop the others")
    }

    @Test
    func aFileThatCannotBeDeletedIsReported() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let parent = stores.url("Locked")
        let cache = parent.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        await #expect(throws: PrivacyRemovalError.incomplete) {
            try await stores.remover([.cache: [cache]]).remove([
                PrivacyRemovalRequest(browser: .chrome, category: .cachedFiles, scope: .wholeCategory)
            ])
        }
    }

    @Test
    func theFailureMessageNeverNamesAFile() {
        let message = PrivacyRemovalError.incomplete.localizedDescription
        #expect(message.contains("couldn't be removed"))
    }
}

@Suite
struct BrowserPrivacyInspectorProfileTests {

    @Test
    func countsAndItemsCoverEveryProfile() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let first = stores.url("Default/Cookies")
        let second = stores.url("Profile 1/Cookies")
        try stores.seed(first, "CREATE TABLE cookies (host_key TEXT); INSERT INTO cookies VALUES ('.a.com'), ('.a.com');")
        try stores.seed(second, "CREATE TABLE cookies (host_key TEXT); INSERT INTO cookies VALUES ('.a.com'), ('.b.com');")
        let inspector = stores.inspector([.cookies: [first, second]])

        #expect(await inspector.count(for: .cookies, browser: .chrome) == 4)
        let items = await inspector.items(for: .cookies, browser: .chrome)
        #expect(items.map(\.id) == [".a.com", ".b.com"])
        #expect(items.map(\.count) == [3, 1])
    }

    @Test
    func theCandidateThatExistsIsUsedWhicheverComesFirst() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let legacy = stores.url("Default/Cookies")
        let modern = stores.url("Default/Network/Cookies")
        try stores.seed(modern, "CREATE TABLE cookies (host_key TEXT); INSERT INTO cookies VALUES ('.a.com');")
        let inspector = stores.inspector([.cookies: [legacy, modern]])

        #expect(await inspector.count(for: .cookies, browser: .chrome) == 1)
    }

    @Test
    func downloadsGroupBySiteAcrossProfiles() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let first = stores.url("Default/History")
        let second = stores.url("Profile 1/History")
        for store in [first, second] {
            try stores.seed(store, "CREATE TABLE downloads (id INTEGER PRIMARY KEY, tab_url TEXT); INSERT INTO downloads (tab_url) VALUES ('https://a.com/1');")
        }
        let inspector = stores.inspector([.history: [first, second]])

        let items = await inspector.items(for: .downloadsHistory, browser: .chrome)

        #expect(items.map(\.id) == ["a.com"])
        #expect(items.first?.count == 2)
        #expect(items.first?.hostKey == "a.com")
    }

    @Test
    func aCategoryThisAppCannotReadSaysSo() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let inspector = stores.inspector([:])

        #expect(await inspector.availability(for: .cookies, browser: .safari) == .unsupported)
        #expect(await inspector.availability(for: .downloadsHistory, browser: .firefox) == .unsupported)
        #expect(await inspector.availability(for: .savedPasswords, browser: .firefox) == .unsupported)
    }

    @Test
    func aMissingStoreIsSimplyEmpty() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let inspector = stores.inspector([.cookies: [stores.url("Cookies")], .cache: [stores.url("Cache")]])

        #expect(await inspector.availability(for: .cookies, browser: .chrome) == .available)
        #expect(await inspector.availability(for: .cachedFiles, browser: .chrome) == .available)
        #expect(await stores.inspector([:]).availability(for: .cookies, browser: .firefox) == .available, "Firefox with no profile yet")
    }

    @Test
    func aStoreThatExistsButCannotBeOpenedIsUnreadable() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let cookies = stores.url("Cookies")
        try stores.seed(cookies, "CREATE TABLE cookies (host_key TEXT);")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cookies.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cookies.path) }
        let inspector = stores.inspector([.cookies: [cookies]])

        #expect(await inspector.availability(for: .cookies, browser: .chrome) == .unreadable)
    }

    @Test
    func aFolderThatCannotBeListedIsUnreadable() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let cache = stores.url("Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cache.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path) }
        let inspector = stores.inspector([.cache: [cache]])

        #expect(await inspector.availability(for: .cachedFiles, browser: .chrome) == .unreadable)
    }

    @Test
    func aStoreThatExistsAndOpensIsAvailable() async throws {
        let stores = try Stores()
        defer { TestHelpers.tearDownTempDirectory(stores.root) }
        let cookies = stores.url("Cookies")
        try stores.seed(cookies, "CREATE TABLE cookies (host_key TEXT);")

        #expect(await stores.inspector([.cookies: [cookies]]).availability(for: .cookies, browser: .chrome) == .available)
    }
}

@Suite
struct BrowserProfileDiscoveryTests {

    private func make(_ path: String, in home: URL) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    @Test
    func everyChromiumProfileIsCoveredAndOthersAreNot() throws {
        let home = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(home) }
        let root = "Library/Application Support/Google/Chrome"
        try make("\(root)/Default", in: home)
        try make("\(root)/Profile 2", in: home)
        try make("\(root)/Profile 1", in: home)
        try make("\(root)/System Profile", in: home)
        try make("\(root)/Crashpad", in: home)

        let paths = DefaultBrowserDataPathProvider(homeDirectory: home)
            .dataPaths(for: .chrome, category: .history)
            .filter { $0.lastPathComponent == "History" }
            .map { $0.deletingLastPathComponent().lastPathComponent }

        #expect(paths == ["Default", "Profile 1", "Profile 2"])
    }

    @Test
    func operaKeepsItsFlatProfile() throws {
        let home = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(home) }
        try make("Library/Application Support/com.operasoftware.Opera/Profile 1", in: home)

        let paths = DefaultBrowserDataPathProvider(homeDirectory: home)
            .dataPaths(for: .opera, category: .history)
            .filter { $0.lastPathComponent == "History" }

        #expect(paths.map { $0.deletingLastPathComponent().lastPathComponent } == ["com.operasoftware.Opera"])
    }

    @Test
    func everyFirefoxProfileIsCovered() throws {
        let home = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(home) }
        let root = "Library/Application Support/Firefox/Profiles"
        try make("\(root)/zzzz.default-release", in: home)
        try make("\(root)/aaaa.default", in: home)
        try make("\(root)/mmmm.work", in: home)

        let profiles = DefaultBrowserDataPathProvider(homeDirectory: home)
            .dataPaths(for: .firefox, category: .cookies)
            .filter { $0.lastPathComponent == "cookies.sqlite" }
            .map { $0.deletingLastPathComponent().lastPathComponent }

        #expect(profiles == ["aaaa.default", "mmmm.work", "zzzz.default-release"])
    }

    @Test
    func theQuickScanReachesExtensionsInEveryChromiumBrowserAndProfile() throws {
        let home = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(home) }
        try make("Library/Application Support/BraveSoftware/Brave-Browser/Default/Extensions", in: home)
        try make("Library/Application Support/Google/Chrome/Profile 1/Extensions", in: home)
        try make("Library/Application Support/Arc/User Data/Default/Extensions", in: home)

        let directories = DefaultBrowserDataPathProvider(homeDirectory: home).chromiumExtensionDirectories()
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0.path) }

        #expect(existing.count == 3)
    }
}
