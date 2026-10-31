// BrowserPrivacyStore.swift
// Maps each (Browser, ProtectionPrivacyCategory) pair to the on-disk store the Protection Manager reads counts/items from and deletes — shared by BrowserPrivacyInspector and BrowserPrivacyRemover so the two never drift.

import Foundation

/// Which engine family a browser belongs to — they share store layouts and
/// SQLite schemas within a family.
enum BrowserFamily: Sendable, Equatable {
    case chromium, firefox, safari

    init(_ browser: Browser) {
        switch browser {
        case .safari:  self = .safari
        case .firefox: self = .firefox
        case .chrome, .brave, .arc, .opera, .edge: self = .chromium
        }
    }
}

/// How an expandable SQLite category enumerates and deletes its rows.
enum PrivacyItemKind: Sendable {
    /// Count only; no per-item rows (informational stores, autofill).
    case plain
    /// Group by a host column; delete by host value (`DELETE … WHERE host IN …`).
    case cookiesByHost(String)
    /// Group rows by the domain parsed from a URL column; delete the rows whose
    /// URL belongs to that domain.
    case rowsBySite(String)
}

/// The per-site grouping shared by listing and removal, so a row removed for a
/// site is exactly a row that was listed under it.
enum BrowserPrivacySite {
    static func key(forURL urlString: String) -> String {
        URL(string: urlString)?.host ?? (urlString.isEmpty ? "—" : urlString)
    }
}

/// The resolved store for a `(browser, category)` pair.
enum BrowserPrivacyStore: Sendable {
    /// One candidate database per profile. Any may be missing: a browser's path
    /// list names every location it might use, and readers skip the absent ones.
    case sqlite(dbs: [URL], table: String, kind: PrivacyItemKind)
    case files([URL])
    /// The app can't read this category for this browser's format at all.
    case none
}

/// Resolves the store for a `(browser, category)` pair. Reuses the existing
/// `BrowserDataPathProviding` for the cookie/history/cache/web-data files and
/// derives the password + session stores from the profile directory.
struct BrowserPrivacyStoreLocator: Sendable {

    let pathProvider: BrowserDataPathProviding

    func store(for category: ProtectionPrivacyCategory, browser: Browser) -> BrowserPrivacyStore {
        let family = BrowserFamily(browser)
        switch category {
        case .cachedFiles:
            return .files(pathProvider.dataPaths(for: browser, category: .cache))
        case .tabsFromLastSession:
            return .files(sessionPaths(browser: browser, family: family))
        case .savedPasswords:
            return passwordStore(browser: browser, family: family)
        case .autofillValues:
            return autofillStore(browser: browser, family: family)
        case .cookies:
            return cookieStore(browser: browser, family: family)
        case .browsingHistory:
            return historyStore(browser: browser, family: family, downloads: false)
        case .downloadsHistory:
            return historyStore(browser: browser, family: family, downloads: true)
        case .searchQueries:
            return searchStore(browser: browser, family: family)
        }
    }

    // MARK: - Per-category resolution

    private func cookieStore(browser: Browser, family: BrowserFamily) -> BrowserPrivacyStore {
        let dbs = mainDBs(pathProvider.dataPaths(for: browser, category: .cookies))
        switch family {
        case .chromium: return .sqlite(dbs: dbs, table: "cookies", kind: .cookiesByHost("host_key"))
        case .firefox:  return .sqlite(dbs: dbs, table: "moz_cookies", kind: .cookiesByHost("host"))
        case .safari:   return .none // binarycookies — not SQLite
        }
    }

    private func historyStore(browser: Browser, family: BrowserFamily, downloads: Bool) -> BrowserPrivacyStore {
        let dbs = mainDBs(pathProvider.dataPaths(for: browser, category: .history))
        switch family {
        case .chromium:
            return downloads
                ? .sqlite(dbs: dbs, table: "downloads", kind: .rowsBySite("tab_url"))
                : .sqlite(dbs: dbs, table: "urls", kind: .rowsBySite("url"))
        case .firefox:
            return downloads ? .none : .sqlite(dbs: dbs, table: "moz_places", kind: .rowsBySite("url"))
        case .safari:
            return downloads ? .none : .sqlite(dbs: dbs, table: "history_items", kind: .rowsBySite("url"))
        }
    }

    private func searchStore(browser: Browser, family: BrowserFamily) -> BrowserPrivacyStore {
        switch family {
        case .chromium:
            // Search Queries is informational (count only); no per-item rows.
            let dbs = mainDBs(pathProvider.dataPaths(for: browser, category: .history))
            return .sqlite(dbs: dbs, table: "keyword_search_terms", kind: .plain)
        case .firefox, .safari:
            return .none
        }
    }

    private func autofillStore(browser: Browser, family: BrowserFamily) -> BrowserPrivacyStore {
        let dbs = mainDBs(pathProvider.dataPaths(for: browser, category: .savedForms))
        switch family {
        case .chromium: return .sqlite(dbs: dbs, table: "autofill", kind: .plain)
        case .firefox:  return .sqlite(dbs: dbs, table: "moz_formhistory", kind: .plain)
        case .safari:   return .none
        }
    }

    private func passwordStore(browser: Browser, family: BrowserFamily) -> BrowserPrivacyStore {
        switch family {
        case .chromium:
            let dbs = profileDirectories(browser: browser).map { $0.appendingPathComponent("Login Data") }
            return .sqlite(dbs: dbs, table: "logins", kind: .plain)
        case .firefox, .safari:
            return .none
        }
    }

    // MARK: - Derived paths

    /// Every profile directory the browser's history paths name.
    func profileDirectories(browser: Browser) -> [URL] {
        mainDBs(pathProvider.dataPaths(for: browser, category: .history))
            .map { $0.deletingLastPathComponent() }
    }

    private func sessionPaths(browser: Browser, family: BrowserFamily) -> [URL] {
        profileDirectories(browser: browser).flatMap { profile -> [URL] in
            switch family {
            case .chromium:
                return [
                    profile.appendingPathComponent("Sessions", isDirectory: true),
                    profile.appendingPathComponent("Current Session"),
                    profile.appendingPathComponent("Current Tabs"),
                    profile.appendingPathComponent("Last Session"),
                    profile.appendingPathComponent("Last Tabs")
                ]
            case .firefox:
                return [
                    profile.appendingPathComponent("sessionstore.jsonlz4"),
                    profile.appendingPathComponent("sessionstore-backups", isDirectory: true)
                ]
            case .safari:
                return [profile.appendingPathComponent("LastSession.plist")]
            }
        }
    }

    /// The main DB files (non-sidecars) from a provider path list.
    private func mainDBs(_ paths: [URL]) -> [URL] {
        paths.filter { url in
            let name = url.lastPathComponent
            return !name.hasSuffix("-shm") && !name.hasSuffix("-wal") && !name.hasSuffix("-journal")
        }
    }
}
