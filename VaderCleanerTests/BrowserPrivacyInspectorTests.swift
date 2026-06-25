// BrowserPrivacyInspectorTests.swift
// Verifies BrowserPrivacyInspector counts categories and enumerates expandable items (cookies by domain, history/search grouped) against seeded temp SQLite stores and temp cache directories.

import XCTest
import SQLite3
@testable import VaderCleaner

final class BrowserPrivacyInspectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrowserPrivacyInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Cookies (grouped by host)

    func test_items_cookies_groupsByHostWithCounts() async throws {
        let db = tempDir.appendingPathComponent("Cookies")
        try seed(db, "CREATE TABLE cookies (host_key TEXT)")
        try insert(db, "INSERT INTO cookies (host_key) VALUES ('.a.com'),('.a.com'),('.b.com')")
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.cookies: [db]]))

        let items = await inspector.items(for: .cookies, browser: .chrome)

        XCTAssertEqual(items.map(\.id), [".a.com", ".b.com"])
        XCTAssertEqual(items.first?.count, 2)
        XCTAssertEqual(items.first?.hostKey, ".a.com")
    }

    func test_count_cookies_totalsAllRows() async throws {
        let db = tempDir.appendingPathComponent("Cookies")
        try seed(db, "CREATE TABLE cookies (host_key TEXT)")
        try insert(db, "INSERT INTO cookies (host_key) VALUES ('.a.com'),('.a.com'),('.b.com')")
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.cookies: [db]]))

        let count = await inspector.count(for: .cookies, browser: .chrome)

        XCTAssertEqual(count, 3)
    }

    // MARK: - Downloads (expandable: grouped by site, carrying row ids for deletion)

    func test_items_downloads_groupsBySiteAndKeepsRowIDs() async throws {
        let db = tempDir.appendingPathComponent("History")
        try seed(db, "CREATE TABLE downloads (id INTEGER PRIMARY KEY, tab_url TEXT)")
        try insert(db, """
            INSERT INTO downloads (tab_url) VALUES
            ('https://a.com/1'),('https://a.com/2'),('https://b.com/')
            """)
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.history: [db]]))

        let items = await inspector.items(for: .downloadsHistory, browser: .chrome)

        XCTAssertEqual(items.map(\.id), ["a.com", "b.com"])
        let a = try XCTUnwrap(items.first { $0.id == "a.com" })
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.rowIDs.sorted(), [1, 2])
    }

    // MARK: - Search queries (informational: count only, no items)

    func test_searchQueries_areInformational_countOnlyNoItems() async throws {
        let db = tempDir.appendingPathComponent("History")
        try seed(db, "CREATE TABLE keyword_search_terms (term TEXT)")
        try insert(db, "INSERT INTO keyword_search_terms (term) VALUES ('swift'),('mac')")
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.history: [db]]))

        let count = await inspector.count(for: .searchQueries, browser: .chrome)
        let items = await inspector.items(for: .searchQueries, browser: .chrome)

        XCTAssertEqual(count, 2)
        XCTAssertTrue(items.isEmpty, "Informational categories have no per-item rows")
    }

    // MARK: - Cache (file count, non-expandable)

    func test_count_cachedFiles_countsFiles() async throws {
        let cache = tempDir.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent("a"))
        try Data().write(to: cache.appendingPathComponent("b"))
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.cache: [cache]]))

        let count = await inspector.count(for: .cachedFiles, browser: .chrome)
        let items = await inspector.items(for: .cachedFiles, browser: .chrome)

        XCTAssertEqual(count, 2)
        XCTAssertTrue(items.isEmpty, "Non-expandable categories have no item rows")
    }

    // MARK: - Informational (count only)

    func test_count_savedPasswords_readsLoginDataBesideHistory() async throws {
        // Login Data is derived from the History DB's parent directory.
        let history = tempDir.appendingPathComponent("History")
        try seed(history, "CREATE TABLE urls (id INTEGER PRIMARY KEY)")
        let logins = tempDir.appendingPathComponent("Login Data")
        try seed(logins, "CREATE TABLE logins (id INTEGER PRIMARY KEY)")
        try insert(logins, "INSERT INTO logins DEFAULT VALUES")
        try insert(logins, "INSERT INTO logins DEFAULT VALUES")
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.history: [history]]))

        let count = await inspector.count(for: .savedPasswords, browser: .chrome)

        XCTAssertEqual(count, 2)
    }

    func test_safariCookies_haveNoEnumerableItems() async throws {
        let file = tempDir.appendingPathComponent("Cookies.binarycookies")
        try Data("binary".utf8).write(to: file)
        let inspector = BrowserPrivacyInspector(pathProvider: Stub(paths: [.cookies: [file]]))

        let items = await inspector.items(for: .cookies, browser: .safari)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Helpers

    private func seed(_ url: URL, _ createSQL: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { sqlite3_close(db); throw NSError(domain: "t", code: 1) }
        defer { sqlite3_close(db) }
        try exec(db, createSQL)
    }

    private func insert(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { sqlite3_close(db); throw NSError(domain: "t", code: 1) }
        defer { sqlite3_close(db) }
        try exec(db, sql)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "t", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private struct Stub: BrowserDataPathProviding {
        let paths: [PrivacyCategory: [URL]]
        func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
            paths[category] ?? []
        }
    }
}
