// BrowserPrivacyRemover.swift
// Removes selected Protection Manager privacy data: deletes cache/session files, empties whole SQLite categories, or deletes the rows of chosen sites, in every profile. Refuses while the target browser is running so a live database is never mutated, and reports anything it couldn't remove.

import Foundation
import SQLite3
import AppKit
import os.log

/// A single removal target: a whole category, or specific items within an
/// expandable one.
public struct PrivacyRemovalRequest: Sendable, Equatable {
    let browser: Browser
    let category: ProtectionPrivacyCategory
    let scope: Scope

    enum Scope: Sendable, Equatable {
        case wholeCategory
        /// Per-item: the cookie hosts or sites to delete.
        case items(hostKeys: [String])
    }
}

enum PrivacyRemovalError: LocalizedError, Equatable {
    /// The target browser is running; removing would risk a locked/half-written
    /// store. The UI surfaces "Quit <browser> to remove these items."
    case browserRunning(Browser)
    /// Every request was attempted, and at least one couldn't be carried out.
    case incomplete

    var errorDescription: String? {
        switch self {
        case .browserRunning(let browser):
            return String(
                localized: "Close \(browser.displayName) first, then try again.",
                bundle: .module,
                comment: "Removal failure when a browser must quit before its data can be cleared."
            )
        case .incomplete:
            return String(
                localized: "Some items couldn't be removed. Quit your browsers, check that VaderCleaner has Full Disk Access, then try again.",
                bundle: .module,
                comment: "Removal failure when a browser's data couldn't be deleted."
            )
        }
    }
}

/// Executes `PrivacyRemovalRequest`s. SQLite deletes run read-write inside a
/// transaction; file categories delete on disk. Refuses outright if a target
/// browser is running. Otherwise every request is attempted, and one that fails
/// doesn't stop the rest.
struct BrowserPrivacyRemover: Sendable {

    typealias IsRunning = @Sendable (Browser) -> Bool

    private let worker: RemoverWorker
    private let isBrowserRunning: IsRunning

    init(
        pathProvider: BrowserDataPathProviding,
        isBrowserRunning: @escaping IsRunning = BrowserPrivacyRemover.defaultIsRunning
    ) {
        self.worker = RemoverWorker(
            locator: BrowserPrivacyStoreLocator(pathProvider: pathProvider)
        )
        self.isBrowserRunning = isBrowserRunning
    }

    /// Removes every request. Throws `browserRunning` (before deleting anything)
    /// if any target browser is open, and `incomplete` afterwards if anything
    /// couldn't be removed.
    func remove(_ requests: [PrivacyRemovalRequest]) async throws {
        for browser in Set(requests.map(\.browser)) where isBrowserRunning(browser) {
            throw PrivacyRemovalError.browserRunning(browser)
        }
        guard await worker.remove(requests) else {
            throw PrivacyRemovalError.incomplete
        }
    }

    /// Production running-check: any app with the browser's bundle id is active.
    static let defaultIsRunning: IsRunning = { browser in
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty
    }
}

private actor RemoverWorker {

    private let locator: BrowserPrivacyStoreLocator
    /// See `InspectorWorker.fileManager` — the shared instance, held directly
    /// because no caller or test ever supplied a different one.
    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.personal.VaderCleaner", category: "BrowserPrivacyRemover")

    init(locator: BrowserPrivacyStoreLocator) {
        self.locator = locator
    }

    /// Whether everything asked for is gone.
    func remove(_ requests: [PrivacyRemovalRequest]) -> Bool {
        var allRemoved = true
        for request in requests {
            switch locator.store(for: request.category, browser: request.browser) {
            case .none:
                continue
            case .files(let paths):
                allRemoved = deleteFiles(paths) && allRemoved
            case .sqlite(let dbs, let table, let kind):
                for db in dbs where fileManager.fileExists(atPath: db.path) {
                    let removed = runDelete(db: db) { handle in
                        self.statements(for: request.scope, table: table, kind: kind, handle: handle)
                    }
                    allRemoved = removed && allRemoved
                }
            }
        }
        return allRemoved
    }

    private func deleteFiles(_ paths: [URL]) -> Bool {
        var allRemoved = true
        for url in paths where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                log.error("Could not remove browser data: \(error.localizedDescription, privacy: .private)")
                allRemoved = false
            }
        }
        return allRemoved
    }

    private func statements(
        for scope: PrivacyRemovalRequest.Scope,
        table: String,
        kind: PrivacyItemKind,
        handle: OpaquePointer
    ) -> [String]? {
        let linked = Self.linkedTables(of: table).filter { tableExists($0.name, handle: handle) }
        switch scope {
        case .wholeCategory:
            return ["DELETE FROM \"\(table)\""] + linked.map { "DELETE FROM \"\($0.name)\"" }
        case .items(let hostKeys):
            switch kind {
            case .cookiesByHost(let column):
                return hostKeys.chunked(into: 400).map { chunk in
                    let list = chunk.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                    return "DELETE FROM \"\(table)\" WHERE \"\(column)\" IN (\(list))"
                }
            case .rowsBySite(let urlColumn):
                guard let rowIDs = rowIDs(ofSites: Set(hostKeys), table: table, urlColumn: urlColumn, handle: handle) else {
                    return nil
                }
                return rowIDs.chunked(into: 400).flatMap { chunk -> [String] in
                    let list = chunk.map(String.init).joined(separator: ",")
                    return ["DELETE FROM \"\(table)\" WHERE rowid IN (\(list))"]
                        + linked.map { "DELETE FROM \"\($0.name)\" WHERE \"\($0.keyColumn)\" IN (\(list))" }
                }
            case .plain:
                return [] // informational stores are never deleted
            }
        }
    }

    /// Tables keyed to a row of `table`. Chromium keeps a download's actual URL
    /// in `downloads_url_chains`, not `downloads`, so removing only the row it
    /// hangs off would leave the very thing the user asked to forget.
    private static func linkedTables(of table: String) -> [(name: String, keyColumn: String)] {
        guard table == "downloads" else { return [] }
        return [
            ("downloads_url_chains", "id"),
            ("downloads_slices", "download_id"),
            ("downloads_reroute_info", "download_id")
        ]
    }

    private func tableExists(_ name: String, handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// The rows listed under the given sites right now, so a row added since the
    /// list was read goes with its site and a reused rowid can't take a stranger.
    /// `nil` means the rows couldn't be read, not that there are none.
    private func rowIDs(ofSites sites: Set<String>, table: String, urlColumn: String, handle: OpaquePointer) -> [Int64]? {
        var statement: OpaquePointer?
        let sql = "SELECT rowid, \"\(urlColumn)\" FROM \"\(table)\""
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var matches: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let urlString = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            if sites.contains(BrowserPrivacySite.key(forURL: urlString)) {
                matches.append(sqlite3_column_int64(statement, 0))
            }
        }
        return matches
    }

    /// Opens the DB read-write and runs the statements in one transaction, so a
    /// row and the rows linked to it go together or not at all. Reports whether
    /// the transaction committed. A locked DB (browser still open despite the
    /// guard) fails rather than corrupting anything — SQLite is atomic. `nil`
    /// statements mean they couldn't be worked out, which also counts as failing.
    private func runDelete(db url: URL, statements: (OpaquePointer) -> [String]?) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle = db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        guard let statements = statements(handle) else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return false
        }
        for sql in statements where sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return false
        }
        return sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
