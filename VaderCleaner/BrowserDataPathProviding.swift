// BrowserDataPathProviding.swift
// Maps each (Browser, PrivacyCategory) pair to the on-disk locations the BrowserDataClearer reads and removes — concrete production resolver plus protocol test seam.

import Foundation

/// Test seam between `BrowserDataClearer` and the macOS browser data
/// layout. The clearer knows nothing about where Chrome's `History` lives;
/// the provider does. Tests inject a stub that returns paths under a temp
/// directory so every clearer / view-model test runs hermetically.
protocol BrowserDataPathProviding {
    /// All on-disk paths to read (for size preview) or remove (for clear)
    /// for a given `(browser, category)` pair. Missing paths are not
    /// filtered here — the clearer skips ones that don't exist — so callers
    /// receive the full set the provider knows about.
    func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL]
}

/// Production resolver. Returns the real macOS paths for each
/// `(browser, category)` pair, anchored to an injectable home directory so
/// tests can drive every code path without touching the user's actual data.
struct DefaultBrowserDataPathProvider: BrowserDataPathProviding {

    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
        switch browser {
        case .safari:
            return safariPaths(category: category)
        case .firefox:
            return firefoxPaths(category: category)
        case .chrome, .brave, .arc, .opera, .edge:
            return chromiumPaths(browser: browser, category: category)
        }
    }

    // MARK: - Safari

    /// Safari ships both legacy paths (`~/Library/Safari`, `~/Library/Cookies`)
    /// and sandbox-container paths (`~/Library/Containers/com.apple.Safari/...`)
    /// on modern macOS. Some users have both populated depending on upgrade
    /// history, so the provider emits both and the clearer skips whichever
    /// doesn't exist on a given machine.
    private func safariPaths(category: PrivacyCategory) -> [URL] {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let safariLegacy = library.appendingPathComponent("Safari", isDirectory: true)
        let containerLibrary = library
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("com.apple.Safari", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        let safariContainer = containerLibrary.appendingPathComponent("Safari", isDirectory: true)

        switch category {
        case .history:
            // History.db is the SQLite store; -shm/-wal are sidecars that
            // SQLite recreates lazily, so removing them alongside the main
            // file keeps the on-disk state coherent.
            return [
                safariLegacy.appendingPathComponent("History.db"),
                safariLegacy.appendingPathComponent("History.db-shm"),
                safariLegacy.appendingPathComponent("History.db-wal"),
                safariContainer.appendingPathComponent("History.db"),
                safariContainer.appendingPathComponent("History.db-shm"),
                safariContainer.appendingPathComponent("History.db-wal")
            ]
        case .downloads:
            return [
                safariLegacy.appendingPathComponent("Downloads.plist"),
                safariContainer.appendingPathComponent("Downloads.plist")
            ]
        case .cookies:
            return [
                library.appendingPathComponent("Cookies", isDirectory: true)
                       .appendingPathComponent("Cookies.binarycookies"),
                containerLibrary.appendingPathComponent("Cookies", isDirectory: true)
                                .appendingPathComponent("Cookies.binarycookies")
            ]
        case .cache:
            return [
                library.appendingPathComponent("Caches", isDirectory: true)
                       .appendingPathComponent("com.apple.Safari", isDirectory: true),
                containerLibrary.appendingPathComponent("Caches", isDirectory: true)
                                .appendingPathComponent("com.apple.Safari", isDirectory: true)
            ]
        case .savedForms:
            return [
                safariLegacy.appendingPathComponent("Form Values"),
                safariContainer.appendingPathComponent("Form Values")
            ]
        }
    }

    // MARK: - Chromium

    /// Each Chromium-based browser keeps its data under a vendor-specific
    /// `Application Support` root with a near-identical layout: `Default/`
    /// for the primary profile, `History` for browsing + downloads,
    /// `Cookies` for cookies, `Web Data` for autofill / saved forms.
    /// Caches live under `~/Library/Caches/<vendor>/...`.
    private func chromiumPaths(browser: Browser, category: PrivacyCategory) -> [URL] {
        guard let layout = chromiumLayout(for: browser) else { return [] }

        switch category {
        case .history:
            // The History SQLite stores both browsing and downloads, so a
            // user clearing only "Downloads" via `.downloads` still leaves
            // the browsing entry intact via this path. We do *not* remove
            // History under the .downloads category — see below.
            return layout.profilePath
                .map { [$0.appendingPathComponent("History"),
                        $0.appendingPathComponent("History-journal")] }
                ?? []
        case .downloads:
            // Chromium stores download history inside the same `History`
            // SQLite as browsing history, so `.downloads` returns the same
            // paths. The view-model deduplicates URLs when summing
            // `totalSelectedSize` and when handing paths to the clearer, so
            // checking both `.history` and `.downloads` doesn't double-count
            // bytes or attempt a redundant remove.
            return layout.profilePath
                .map { [$0.appendingPathComponent("History"),
                        $0.appendingPathComponent("History-journal")] }
                ?? []
        case .cookies:
            return layout.profilePath
                .map { [$0.appendingPathComponent("Cookies"),
                        $0.appendingPathComponent("Cookies-journal")] }
                ?? []
        case .cache:
            return layout.cachePath.map { [$0] } ?? []
        case .savedForms:
            return layout.profilePath
                .map { [$0.appendingPathComponent("Web Data"),
                        $0.appendingPathComponent("Web Data-journal")] }
                ?? []
        }
    }

    private struct ChromiumLayout {
        let profilePath: URL?
        let cachePath: URL?
    }

    private func chromiumLayout(for browser: Browser) -> ChromiumLayout? {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)

        switch browser {
        case .chrome:
            return ChromiumLayout(
                profilePath: appSupport.appendingPathComponent("Google/Chrome/Default", isDirectory: true),
                cachePath:   caches.appendingPathComponent("Google/Chrome", isDirectory: true)
            )
        case .brave:
            return ChromiumLayout(
                profilePath: appSupport.appendingPathComponent("BraveSoftware/Brave-Browser/Default", isDirectory: true),
                cachePath:   caches.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
            )
        case .edge:
            return ChromiumLayout(
                profilePath: appSupport.appendingPathComponent("Microsoft Edge/Default", isDirectory: true),
                cachePath:   caches.appendingPathComponent("Microsoft Edge", isDirectory: true)
            )
        case .arc:
            // Arc stores profile data under `Arc/User Data/Default`, mirroring
            // Chromium's nested-User-Data layout; cache lives one level up.
            return ChromiumLayout(
                profilePath: appSupport.appendingPathComponent("Arc/User Data/Default", isDirectory: true),
                cachePath:   caches.appendingPathComponent("Arc", isDirectory: true)
            )
        case .opera:
            // Opera flattens the profile — no `Default` subdirectory.
            return ChromiumLayout(
                profilePath: appSupport.appendingPathComponent("com.operasoftware.Opera", isDirectory: true),
                cachePath:   caches.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)
            )
        case .safari, .firefox:
            return nil
        }
    }

    // MARK: - Firefox

    /// Firefox profiles live under `Profiles/<8-char-rand>.default*`. We
    /// enumerate the `Profiles/` directory at call time and pick the first
    /// directory whose name contains `.default` — that matches both the
    /// historical `<rand>.default` and the modern `<rand>.default-release`
    /// variants. Returns no paths when no profile exists yet (e.g. the user
    /// never launched Firefox), which is the right default for the clearer.
    private func firefoxPaths(category: PrivacyCategory) -> [URL] {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)

        let profilesRoot = appSupport
            .appendingPathComponent("Firefox", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
        let cacheProfilesRoot = caches
            .appendingPathComponent("Firefox", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)

        let profileDir = firefoxProfileDirectory(at: profilesRoot)
        let cacheProfileDir = firefoxProfileDirectory(at: cacheProfilesRoot)

        switch category {
        case .history:
            // places.sqlite stores both browsing history and download history
            // in Firefox; same caveat as Chromium's `History` file applies.
            return profileDir.map { [$0.appendingPathComponent("places.sqlite")] } ?? []
        case .downloads:
            // Firefox stores download history inside places.sqlite alongside
            // browsing history. Same dedup contract as Chromium — see the
            // chromiumPaths(.downloads) note.
            return profileDir.map { [$0.appendingPathComponent("places.sqlite")] } ?? []
        case .cookies:
            return profileDir.map { [$0.appendingPathComponent("cookies.sqlite")] } ?? []
        case .cache:
            return cacheProfileDir.map { [$0.appendingPathComponent("cache2", isDirectory: true)] } ?? []
        case .savedForms:
            return profileDir.map { [$0.appendingPathComponent("formhistory.sqlite")] } ?? []
        }
    }

    private func firefoxProfileDirectory(at profilesRoot: URL) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return entries.first { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && url.lastPathComponent.contains(".default")
        }
    }
}
