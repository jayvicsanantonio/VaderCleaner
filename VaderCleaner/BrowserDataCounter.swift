// BrowserDataCounter.swift
// Counts the number of privacy items a (Browser, PrivacyCategory) pair holds — cache files on disk, or rows in the browser's SQLite store — so the Protection Manager can show real per-category item counts.

import Foundation
import SQLite3

/// Reads item counts for the Privacy feature, the count analogue of
/// `BrowserDataClearer`'s size preview. Cache categories count files on disk;
/// the SQLite-backed categories (history, downloads, cookies, saved forms) open
/// the browser's store read-only and run `SELECT count(*)` on the matching
/// table.
///
/// Like the clearer, all "where does Chrome keep its cookies?" knowledge routes
/// through the injected `BrowserDataPathProviding`, so the whole pipeline is
/// testable against a temp directory. Every failure (missing DB, locked file,
/// absent table) degrades to a count of 0 rather than throwing — a count is
/// best-effort and must never sink the scan.
struct BrowserDataCounter: Sendable {

    private let worker: BrowserDataCountWorker

    init(pathProvider: BrowserDataPathProviding, fileManager: FileManager = .default) {
        self.worker = BrowserDataCountWorker(pathProvider: pathProvider, fileManager: fileManager)
    }

    /// The number of items `(browser, category)` holds. Missing or unreadable
    /// stores count 0.
    func count(for category: PrivacyCategory, browser: Browser) async throws -> Int {
        try await worker.count(for: category, browser: browser)
    }
}

/// Serializes the filesystem + SQLite work off the main actor, mirroring
/// `BrowserDataClearer`'s worker.
private actor BrowserDataCountWorker {

    private let pathProvider: BrowserDataPathProviding
    private let fileManager: FileManager

    init(pathProvider: BrowserDataPathProviding, fileManager: FileManager) {
        self.pathProvider = pathProvider
        self.fileManager = fileManager
    }

    func count(for category: PrivacyCategory, browser: Browser) throws -> Int {
        try Task.checkCancellation()
        switch plan(for: browser, category: category) {
        case .none:
            return 0
        case .files:
            return fileCount(under: pathProvider.dataPaths(for: browser, category: .cache))
        case .sqlite(let dbCategory, let table):
            // The store + its sidecars come from the provider; the main DB is
            // the one without a `-shm` / `-wal` / `-journal` suffix.
            let candidates = mainDatabaseFiles(
                pathProvider.dataPaths(for: browser, category: dbCategory)
            )
            guard let db = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                return 0
            }
            return rowCount(databaseAt: db, table: table)
        }
    }

    // MARK: - Plan

    private enum CountPlan {
        /// Count files on disk (cache directories).
        case files
        /// Count rows of `table` in the main DB the provider returns for
        /// `dbCategory`. Chromium downloads live in the History DB, so its
        /// `dbCategory` is `.history` while the table is `downloads`.
        case sqlite(dbCategory: PrivacyCategory, table: String)
        /// No reliable count (e.g. Safari's binary cookies / encrypted forms).
        case none
    }

    private func plan(for browser: Browser, category: PrivacyCategory) -> CountPlan {
        if category == .cache { return .files }
        switch family(of: browser) {
        case .chromium:
            switch category {
            case .history:    return .sqlite(dbCategory: .history, table: "urls")
            case .downloads:  return .sqlite(dbCategory: .history, table: "downloads")
            case .cookies:    return .sqlite(dbCategory: .cookies, table: "cookies")
            case .savedForms: return .sqlite(dbCategory: .savedForms, table: "autofill")
            case .cache:      return .files
            }
        case .firefox:
            switch category {
            case .history:    return .sqlite(dbCategory: .history, table: "moz_places")
            case .cookies:    return .sqlite(dbCategory: .cookies, table: "moz_cookies")
            case .savedForms: return .sqlite(dbCategory: .savedForms, table: "moz_formhistory")
            // Firefox download history lives in places.sqlite as annotations,
            // not a standalone table — no reliable standalone count.
            case .downloads:  return .none
            case .cache:      return .files
            }
        case .safari:
            switch category {
            case .history:    return .sqlite(dbCategory: .history, table: "history_items")
            case .cache:      return .files
            // Binary cookies, plist downloads, and encrypted form values aren't
            // SQLite, so they have no row count to read.
            case .cookies, .downloads, .savedForms: return .none
            }
        }
    }

    private enum BrowserFamily { case chromium, firefox, safari }

    private func family(of browser: Browser) -> BrowserFamily {
        switch browser {
        case .safari:  return .safari
        case .firefox: return .firefox
        case .chrome, .brave, .arc, .opera, .edge: return .chromium
        }
    }

    /// The candidate main DB files from a provider path list — the entries that
    /// aren't SQLite sidecars.
    private func mainDatabaseFiles(_ paths: [URL]) -> [URL] {
        paths.filter { url in
            let name = url.lastPathComponent
            return !name.hasSuffix("-shm")
                && !name.hasSuffix("-wal")
                && !name.hasSuffix("-journal")
        }
    }

    // MARK: - File counting

    /// Total number of files (not directories) under the given paths. A path
    /// that is itself a file counts as 1; a directory is walked recursively.
    private func fileCount(under paths: [URL]) -> Int {
        var total = 0
        for url in paths {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                total += 1
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }
            for case let entry as URL in enumerator {
                let entryIsDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !entryIsDir { total += 1 }
            }
        }
        return total
    }

    // MARK: - SQLite counting

    /// `SELECT count(*) FROM <table>` against a read-only, immutable open of the
    /// database (immutable avoids "database is locked" while the browser runs).
    /// `table` is always one of the hardcoded names above, so the interpolation
    /// is not an injection vector. Any failure degrades to 0.
    private func rowCount(databaseAt url: URL, table: String) -> Int {
        // `immutable=1` lets us read a DB the browser may have open, at the cost
        // of a possibly slightly stale count — acceptable for a headline number.
        let uri = url.absoluteString + "?immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return 0
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT count(*) FROM \"\(table)\""
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
