// BrowserPrivacyRemoverTests.swift
// Verifies BrowserPrivacyRemover deletes exactly the selected cookie hosts / history rows, empties whole categories, removes cache files, and refuses when the target browser is running.

import XCTest
import SQLite3
@testable import VaderCleaner

final class BrowserPrivacyRemoverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrowserPrivacyRemoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Per-item cookie removal

    func test_remove_cookieHosts_deletesOnlyThoseHosts() async throws {
        let db = tempDir.appendingPathComponent("Cookies")
        try seed(db, "CREATE TABLE cookies (host_key TEXT)")
        try exec(db, "INSERT INTO cookies (host_key) VALUES ('.a.com'),('.a.com'),('.b.com')")
        let remover = makeRemover(paths: [.cookies: [db]])

        try await remover.remove([
            PrivacyRemovalRequest(browser: .chrome, category: .cookies,
                                  scope: .items(hostKeys: [".a.com"], rowIDs: []))
        ])

        XCTAssertEqual(try rowCount(db, "SELECT count(*) FROM cookies"), 1)
        XCTAssertEqual(try rowCount(db, "SELECT count(*) FROM cookies WHERE host_key='.b.com'"), 1)
    }

    // MARK: - Per-item history removal (by rowid)

    func test_remove_historyRowIDs_deletesOnlyThoseRows() async throws {
        let db = tempDir.appendingPathComponent("History")
        try seed(db, "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT)")
        try exec(db, "INSERT INTO urls (url) VALUES ('https://a.com/1'),('https://a.com/2'),('https://b.com/')")
        let remover = makeRemover(paths: [.history: [db]])

        try await remover.remove([
            PrivacyRemovalRequest(browser: .chrome, category: .browsingHistory,
                                  scope: .items(hostKeys: [], rowIDs: [1, 2]))
        ])

        XCTAssertEqual(try rowCount(db, "SELECT count(*) FROM urls"), 1)
        XCTAssertEqual(try rowCount(db, "SELECT count(*) FROM urls WHERE url='https://b.com/'"), 1)
    }

    // MARK: - Whole category

    func test_remove_wholeCategory_emptiesTheTable() async throws {
        let db = tempDir.appendingPathComponent("Cookies")
        try seed(db, "CREATE TABLE cookies (host_key TEXT)")
        try exec(db, "INSERT INTO cookies (host_key) VALUES ('.a.com'),('.b.com')")
        let remover = makeRemover(paths: [.cookies: [db]])

        try await remover.remove([
            PrivacyRemovalRequest(browser: .chrome, category: .cookies, scope: .wholeCategory)
        ])

        XCTAssertEqual(try rowCount(db, "SELECT count(*) FROM cookies"), 0)
    }

    func test_remove_cacheFiles_deletesThem() async throws {
        let cache = tempDir.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent("a"))
        let remover = makeRemover(paths: [.cache: [cache]])

        try await remover.remove([
            PrivacyRemovalRequest(browser: .chrome, category: .cachedFiles, scope: .wholeCategory)
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: - Running-browser guard

    func test_remove_whenBrowserRunning_throwsAndDeletesNothing() async throws {
        let db = tempDir.appendingPathComponent("Cookies")
        try seed(db, "CREATE TABLE cookies (host_key TEXT)")
        try exec(db, "INSERT INTO cookies (host_key) VALUES ('.a.com')")
        let remover = BrowserPrivacyRemover(
            pathProvider: Stub(paths: [.cookies: [db]]),
            isBrowserRunning: { _ in true }
        )

        do {
            try await remover.remove([
                PrivacyRemovalRequest(browser: .chrome, category: .cookies, scope: .wholeCategory)
            ])
            XCTFail("Expected browserRunning to be thrown")
        } catch PrivacyRemovalError.browserRunning(let b) {
            XCTAssertEqual(b, .chrome)
        }
        XCTAssertEqual(try rowCount(db, "SELECT count(*) FROM cookies"), 1, "Nothing removed while the browser is running")
    }

    // MARK: - Helpers

    private func makeRemover(paths: [PrivacyCategory: [URL]]) -> BrowserPrivacyRemover {
        BrowserPrivacyRemover(pathProvider: Stub(paths: paths), isBrowserRunning: { _ in false })
    }

    private func seed(_ url: URL, _ createSQL: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { sqlite3_close(db); throw NSError(domain: "t", code: 1) }
        defer { sqlite3_close(db) }
        try exec(db, createSQL)
    }

    private func exec(_ url: URL, _ sql: String) throws {
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

    private func rowCount(_ url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { sqlite3_close(db); throw NSError(domain: "t", code: 1) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "t", code: 3) }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private struct Stub: BrowserDataPathProviding {
        let paths: [PrivacyCategory: [URL]]
        func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
            paths[category] ?? []
        }
    }
}
