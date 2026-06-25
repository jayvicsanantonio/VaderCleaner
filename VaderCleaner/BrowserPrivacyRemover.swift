// BrowserPrivacyRemover.swift
// Removes selected Protection Manager privacy data: deletes cache/session files, empties whole SQLite categories, or deletes individual rows (cookies by host, history/search by rowid). Refuses while the target browser is running so a live database is never mutated.

import Foundation
import SQLite3
import AppKit

/// A single removal target: a whole category, or specific items within an
/// expandable one.
struct PrivacyRemovalRequest: Sendable, Equatable {
    let browser: Browser
    let category: ProtectionPrivacyCategory
    let scope: Scope

    enum Scope: Sendable, Equatable {
        case wholeCategory
        /// Per-item: cookie hosts and/or table rowids to delete.
        case items(hostKeys: [String], rowIDs: [Int64])
    }
}

enum PrivacyRemovalError: Error, Equatable {
    /// The target browser is running; removing would risk a locked/half-written
    /// store. The UI surfaces "Quit <browser> to remove these items."
    case browserRunning(Browser)
}

/// Executes `PrivacyRemovalRequest`s. SQLite deletes run read-write inside a
/// transaction; file categories delete on disk. Refuses outright if a target
/// browser is running.
struct BrowserPrivacyRemover: Sendable {

    typealias IsRunning = @Sendable (Browser) -> Bool

    private let worker: RemoverWorker
    private let isBrowserRunning: IsRunning

    init(
        pathProvider: BrowserDataPathProviding,
        fileManager: FileManager = .default,
        isBrowserRunning: @escaping IsRunning = BrowserPrivacyRemover.defaultIsRunning
    ) {
        self.worker = RemoverWorker(
            locator: BrowserPrivacyStoreLocator(pathProvider: pathProvider),
            fileManager: fileManager
        )
        self.isBrowserRunning = isBrowserRunning
    }

    /// Removes every request. Throws `browserRunning` (before deleting anything)
    /// if any target browser is open.
    func remove(_ requests: [PrivacyRemovalRequest]) async throws {
        for browser in Set(requests.map(\.browser)) where isBrowserRunning(browser) {
            throw PrivacyRemovalError.browserRunning(browser)
        }
        await worker.remove(requests)
    }

    /// Production running-check: any app with the browser's bundle id is active.
    static let defaultIsRunning: IsRunning = { browser in
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty
    }
}

private actor RemoverWorker {

    private let locator: BrowserPrivacyStoreLocator
    private let fileManager: FileManager

    init(locator: BrowserPrivacyStoreLocator, fileManager: FileManager) {
        self.locator = locator
        self.fileManager = fileManager
    }

    func remove(_ requests: [PrivacyRemovalRequest]) {
        for request in requests {
            switch locator.store(for: request.category, browser: request.browser) {
            case .none:
                continue
            case .files(let dirs):
                deleteFiles(dirs)
            case .sqlite(let db, let table, let kind):
                guard fileManager.fileExists(atPath: db.path) else { continue }
                switch request.scope {
                case .wholeCategory:
                    runDelete(db: db, sql: "DELETE FROM \"\(table)\"")
                case .items(let hostKeys, let rowIDs):
                    deleteItems(db: db, table: table, kind: kind, hostKeys: hostKeys, rowIDs: rowIDs)
                }
            }
        }
    }

    private func deleteFiles(_ paths: [URL]) {
        for url in paths where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func deleteItems(db: URL, table: String, kind: PrivacyItemKind, hostKeys: [String], rowIDs: [Int64]) {
        switch kind {
        case .cookiesByHost(let column):
            for chunk in hostKeys.chunked(into: 400) where !chunk.isEmpty {
                let list = chunk.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                runDelete(db: db, sql: "DELETE FROM \"\(table)\" WHERE \"\(column)\" IN (\(list))")
            }
        case .rowsBySite:
            for chunk in rowIDs.chunked(into: 400) where !chunk.isEmpty {
                let list = chunk.map(String.init).joined(separator: ",")
                runDelete(db: db, sql: "DELETE FROM \"\(table)\" WHERE rowid IN (\(list))")
            }
        case .plain:
            break // informational stores are never deleted
        }
    }

    /// Opens the DB read-write and runs `sql` in a transaction. A locked DB
    /// (browser still open despite the guard) just fails silently rather than
    /// corrupting anything — SQLite is atomic.
    private func runDelete(db url: URL, sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
