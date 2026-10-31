// BrowserPrivacyInspector.swift
// Reads per-browser privacy data for the Protection Manager: item counts per category, and — for expandable categories — the individual items (cookies grouped by domain, history/downloads/search rows grouped by site) with the keys needed to delete them.

import Foundation
import SQLite3

/// One selectable entry inside an expandable category — a cookie domain, or a
/// group of history/download rows for one site. `hostKey` is what the remover
/// acts on in every profile: the cookie host, or the site its URLs belong to.
public struct PrivacyItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let count: Int
    var hostKey: String?
}

/// Whether a category's count can be believed. Zero means "nothing there" only
/// when the category is `.available`.
public enum PrivacyDataAvailability: Sendable, Equatable {
    case available
    /// The app doesn't read this category for this browser's storage format.
    case unsupported
    /// The data is on disk but macOS or its permissions won't let the app open it.
    case unreadable
}

/// Inspects a browser's privacy stores for the Protection Manager. Stores are
/// located via `BrowserPrivacyStoreLocator`. Everything is best-effort: a
/// missing or unreadable store yields 0 / no items, never a throw.
struct BrowserPrivacyInspector: Sendable {

    private let worker: InspectorWorker

    init(pathProvider: BrowserDataPathProviding) {
        self.worker = InspectorWorker(
            locator: BrowserPrivacyStoreLocator(pathProvider: pathProvider)
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

    /// Whether `(browser, category)` can be read at all.
    func availability(for category: ProtectionPrivacyCategory, browser: Browser) async -> PrivacyDataAvailability {
        await worker.availability(for: category, browser: browser)
    }
}

/// Off-main filesystem + SQLite work, mirroring the counter/clearer workers.
private actor InspectorWorker {

    private let locator: BrowserPrivacyStoreLocator
    /// The shared instance, which is documented as safe to use from multiple
    /// threads. Held directly rather than injected: no caller or test ever
    /// supplied a different one.
    private let fileManager = FileManager.default

    init(locator: BrowserPrivacyStoreLocator) {
        self.locator = locator
    }

    func count(for category: ProtectionPrivacyCategory, browser: Browser) -> Int {
        switch locator.store(for: category, browser: browser) {
        case .none:
            return 0
        case .files(let dirs):
            return fileCount(under: dirs)
        case .sqlite(let dbs, let table, _):
            return existing(dbs).reduce(0) { $0 + rowCount(db: $1, table: table) }
        }
    }

    func items(for category: ProtectionPrivacyCategory, browser: Browser) -> [PrivacyItem] {
        guard category.isExpandable else { return [] }
        guard case .sqlite(let dbs, let table, let kind) = locator.store(for: category, browser: browser) else {
            return []
        }
        var counts: [String: Int] = [:]
        for db in existing(dbs) {
            switch kind {
            case .cookiesByHost(let hostColumn):
                addCookieCounts(db: db, table: table, hostColumn: hostColumn, to: &counts)
            case .rowsBySite(let urlColumn):
                addSiteCounts(db: db, table: table, urlColumn: urlColumn, to: &counts)
            case .plain:
                break
            }
        }
        return counts
            .map { PrivacyItem(id: $0.key, label: $0.key, count: $0.value, hostKey: $0.key) }
            .sorted { $0.label < $1.label }
    }

    func availability(for category: ProtectionPrivacyCategory, browser: Browser) -> PrivacyDataAvailability {
        switch locator.store(for: category, browser: browser) {
        case .none:
            return .unsupported
        case .files(let paths):
            let readable = paths
                .filter { fileManager.fileExists(atPath: $0.path) }
                .allSatisfy(canList)
            return readable ? .available : .unreadable
        case .sqlite(let dbs, let table, _):
            return existing(dbs).allSatisfy { canQuery(db: $0, table: table) } ? .available : .unreadable
        }
    }

    private func existing(_ urls: [URL]) -> [URL] {
        urls.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Whether a file can be opened or a folder listed. `fileExists` can't say:
    /// it answers yes for items macOS will then refuse to hand over.
    private func canList(_ url: URL) -> Bool {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            return (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil
        }
        return fileManager.isReadableFile(atPath: url.path)
    }

    /// Whether a query against the table gets as far as reading the file. A
    /// missing table (`SQLITE_ERROR`) is an older schema with nothing to show;
    /// anything else, such as `SQLITE_AUTH` or `SQLITE_CANTOPEN`, means the
    /// file itself is off limits.
    private func canQuery(db url: URL, table: String) -> Bool {
        guard let db = openReadOnly(url) else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(db, "SELECT 1 FROM \"\(table)\" LIMIT 1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return status == SQLITE_OK || status == SQLITE_ERROR
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

    private func addCookieCounts(db url: URL, table: String, hostColumn: String, to counts: inout [String: Int]) {
        guard let db = openReadOnly(url) else { return }
        defer { sqlite3_close(db) }
        let sql = "SELECT \"\(hostColumn)\", count(*) FROM \"\(table)\" GROUP BY \"\(hostColumn)\""
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            guard !host.isEmpty else { continue }
            counts[host, default: 0] += Int(sqlite3_column_int64(stmt, 1))
        }
    }

    /// Groups URL rows by the host parsed from the URL, so a category with
    /// thousands of rows collapses into a per-site list the user can act on.
    private func addSiteCounts(db url: URL, table: String, urlColumn: String, to counts: inout [String: Int]) {
        guard let db = openReadOnly(url) else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \"\(urlColumn)\" FROM \"\(table)\"", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let urlString = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            counts[BrowserPrivacySite.key(forURL: urlString), default: 0] += 1
        }
    }
}
