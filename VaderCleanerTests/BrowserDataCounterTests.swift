// BrowserDataCounterTests.swift
// Verifies BrowserDataCounter counts cache files on disk and rows in the browser's SQLite store, and degrades to 0 for missing or unreadable stores.

import XCTest
import SQLite3
@testable import VaderCleaner

final class BrowserDataCounterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrowserDataCounterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Cache (file counting)

    func test_count_cache_countsFilesUnderTheCacheDirectory() async throws {
        // Two files at the top level + one nested = 3; directories don't count.
        let cacheDir = tempDir.appendingPathComponent("Cache", isDirectory: true)
        let nested = cacheDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: cacheDir.appendingPathComponent("a.bin"))
        try Data().write(to: cacheDir.appendingPathComponent("b.bin"))
        try Data().write(to: nested.appendingPathComponent("c.bin"))

        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [.cache: [cacheDir]]))

        let count = try await counter.count(for: .cache, browser: .chrome)

        XCTAssertEqual(count, 3)
    }

    func test_count_cache_missingDirectoryCountsZero() async throws {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [.cache: [missing]]))

        let count = try await counter.count(for: .cache, browser: .chrome)

        XCTAssertEqual(count, 0)
    }

    // MARK: - SQLite (row counting)

    func test_count_history_countsRowsInTheChromiumUrlsTable() async throws {
        // Chromium browsing-history count reads `urls` from the History DB.
        let db = tempDir.appendingPathComponent("History")
        try seedDatabase(at: db, table: "urls", rows: 7)

        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [.history: [db]]))

        let count = try await counter.count(for: .history, browser: .chrome)

        XCTAssertEqual(count, 7)
    }

    func test_count_history_ignoresSidecarsAndPicksTheMainDatabase() async throws {
        // The provider hands back the DB plus its WAL sidecars; only the main
        // file is a real database, so the count must come from it.
        let db = tempDir.appendingPathComponent("History")
        try seedDatabase(at: db, table: "urls", rows: 4)
        try Data("garbage".utf8).write(to: tempDir.appendingPathComponent("History-wal"))
        try Data("garbage".utf8).write(to: tempDir.appendingPathComponent("History-shm"))

        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [
            .history: [
                db,
                tempDir.appendingPathComponent("History-wal"),
                tempDir.appendingPathComponent("History-shm")
            ]
        ]))

        let count = try await counter.count(for: .history, browser: .chrome)

        XCTAssertEqual(count, 4)
    }

    func test_count_cookies_countsRowsInTheFirefoxCookiesTable() async throws {
        // Firefox cookies count reads `moz_cookies` from cookies.sqlite.
        let db = tempDir.appendingPathComponent("cookies.sqlite")
        try seedDatabase(at: db, table: "moz_cookies", rows: 12)

        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [.cookies: [db]]))

        let count = try await counter.count(for: .cookies, browser: .firefox)

        XCTAssertEqual(count, 12)
    }

    func test_count_history_missingDatabaseCountsZero() async throws {
        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [
            .history: [tempDir.appendingPathComponent("History")]
        ]))

        let count = try await counter.count(for: .history, browser: .chrome)

        XCTAssertEqual(count, 0)
    }

    func test_count_safariCookies_hasNoSqliteCountAndReturnsZero() async throws {
        // Safari's binary cookies aren't SQLite, so there's no row count.
        let file = tempDir.appendingPathComponent("Cookies.binarycookies")
        try Data("not a database".utf8).write(to: file)

        let counter = BrowserDataCounter(pathProvider: StubProvider(paths: [.cookies: [file]]))

        let count = try await counter.count(for: .cookies, browser: .safari)

        XCTAssertEqual(count, 0)
    }

    // MARK: - Helpers

    /// Creates a SQLite database at `url` with `table(id INTEGER)` holding
    /// `rows` rows, using the same SQLite3 C API the counter reads with.
    private func seedDatabase(at url: URL, table: String, rows: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE \"\(table)\" (id INTEGER PRIMARY KEY)")
        for _ in 0..<rows {
            try exec(db, "INSERT INTO \"\(table)\" DEFAULT VALUES")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private struct StubProvider: BrowserDataPathProviding {
        let paths: [PrivacyCategory: [URL]]

        func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
            paths[category] ?? []
        }
    }
}
