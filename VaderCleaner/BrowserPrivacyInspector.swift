// BrowserPrivacyInspector.swift
// Reads per-browser privacy data for the Protection Manager: item counts per category, and — for expandable categories — the individual items (cookies grouped by domain, history/downloads/search rows grouped by site) with the keys needed to delete them.

import Foundation
import SQLite3

/// One selectable entry inside an expandable category — a cookie domain, or a
/// group of history/download/search rows for one site/term. Carries the keys the
/// remover needs: `hostKey` for cookies (`DELETE … WHERE host = hostKey`) or
/// `rowIDs` for the other tables (`DELETE … WHERE rowid IN rowIDs`).
struct PrivacyItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let count: Int
    var hostKey: String?
    var rowIDs: [Int64] = []
}

/// Inspects a browser's privacy stores for the Protection Manager. Stores are
/// located via `BrowserPrivacyStoreLocator`. Everything is best-effort: a
/// missing or unreadable store yields 0 / no items, never a throw.
struct BrowserPrivacyInspector: Sendable {

    private let worker: InspectorWorker

    init(pathProvider: BrowserDataPathProviding, fileManager: FileManager = .default) {
        self.worker = InspectorWorker(
            locator: BrowserPrivacyStoreLocator(pathProvider: pathProvider),
            fileManager: fileManager
        )
    }

    /// Total item count for `(browser, category)`.
    func count(for category: ProtectionPrivacyCategory, browser: Browser) async -> Int {
        await worker.count(for: category, browser: browser)
    }

    /// The per-item rows for an expandable category (empty for non-expandable
    /// ones, or where the browser's store can't be enumerated).
    func items(for category: ProtectionPrivacyCategory, browser: Browser) async -> [PrivacyItem] {
        await worker.items(for: category, browser: browser)
    }
}

/// Off-main filesystem + SQLite work, mirroring the counter/clearer workers.
private actor InspectorWorker {

    private let locator: BrowserPrivacyStoreLocator
    private let fileManager: FileManager

    init(locator: BrowserPrivacyStoreLocator, fileManager: FileManager) {
        self.locator = locator
        self.fileManager = fileManager
    }

    func count(for category: ProtectionPrivacyCategory, browser: Browser) -> Int {
        switch locator.store(for: category, browser: browser) {
        case .none:
            return 0
        case .files(let dirs):
            return fileCount(under: dirs)
        case .sqlite(let db, let table, _):
            guard fileManager.fileExists(atPath: db.path) else { return 0 }
            return rowCount(db: db, table: table)
        }
    }

    func items(for category: ProtectionPrivacyCategory, browser: Browser) -> [PrivacyItem] {
        guard category.isExpandable else { return [] }
        guard case .sqlite(let db, let table, let kind) = locator.store(for: category, browser: browser),
              fileManager.fileExists(atPath: db.path) else { return [] }
        switch kind {
        case .cookiesByHost(let hostColumn):
            return cookieItems(db: db, table: table, hostColumn: hostColumn)
        case .rowsBySite(let urlColumn):
            return rowsGroupedBySite(db: db, table: table, urlColumn: urlColumn)
        case .plain:
            return []
        }
    }

    // MARK: - File counting

    private func fileCount(under paths: [URL]) -> Int {
        var total = 0
        for url in paths {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { total += 1; continue }
            guard let e = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let entry as URL in e {
                let d = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !d { total += 1 }
            }
        }
        return total
    }

    // MARK: - SQLite

    private func openReadOnly(_ url: URL) -> OpaquePointer? {
        let uri = url.absoluteString + "?immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private func rowCount(db url: URL, table: String) -> Int {
        guard let db = openReadOnly(url) else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \"\(table)\"", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func cookieItems(db url: URL, table: String, hostColumn: String) -> [PrivacyItem] {
        guard let db = openReadOnly(url) else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT \"\(hostColumn)\", count(*) FROM \"\(table)\" GROUP BY \"\(hostColumn)\" ORDER BY \"\(hostColumn)\""
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var items: [PrivacyItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int64(stmt, 1))
            guard !host.isEmpty else { continue }
            items.append(PrivacyItem(id: host, label: host, count: count, hostKey: host))
        }
        return items
    }

    /// Groups `(rowid, url)` rows by the host parsed from the URL, so a category
    /// with thousands of rows collapses into a per-site list the user can act on.
    private func rowsGroupedBySite(db url: URL, table: String, urlColumn: String) -> [PrivacyItem] {
        guard let db = openReadOnly(url) else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT rowid, \"\(urlColumn)\" FROM \"\(table)\""
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var groups: [String: (count: Int, rowIDs: [Int64])] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let urlString = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let host = URL(string: urlString)?.host ?? (urlString.isEmpty ? "—" : urlString)
            groups[host, default: (0, [])].count += 1
            groups[host]?.rowIDs.append(rowID)
        }
        return groups
            .map { PrivacyItem(id: $0.key, label: $0.key, count: $0.value.count, hostKey: nil, rowIDs: $0.value.rowIDs) }
            .sorted { $0.label < $1.label }
    }
}
