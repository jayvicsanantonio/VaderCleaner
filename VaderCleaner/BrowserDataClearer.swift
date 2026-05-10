// BrowserDataClearer.swift
// Sums on-disk byte sizes and removes every path the BrowserDataPathProviding resolves for a (browser, category) pair, tolerating missing paths so partial browser state never derails a clean run.

import Foundation
import os.log

/// Reads and removes browser data on behalf of the Privacy feature.
///
/// The clearer holds no path knowledge — every "where does Chrome keep its
/// cookies?" question routes to the injected `BrowserDataPathProviding`,
/// which makes the whole pipeline trivially testable against a temp dir.
/// Errors on individual files surface as throws from `clear`; a missing
/// path is treated as already-cleared and silently skipped.
struct BrowserDataClearer {

    typealias Remover = (URL) throws -> Void

    private let pathProvider: BrowserDataPathProviding
    private let worker: BrowserDataWorker

    init(
        pathProvider: BrowserDataPathProviding,
        fileManager: FileManager = .default,
        remover: Remover? = nil
    ) {
        self.pathProvider = pathProvider
        self.worker = BrowserDataWorker(
            pathProvider: pathProvider,
            fileManager: fileManager,
            remover: remover
        )
    }

    /// Sum of bytes across every existing path the provider returns for
    /// `(browser, category)`. Files contribute their `fileSize`,
    /// directories contribute the recursive total. Missing paths are
    /// silently skipped — they contribute 0.
    func previewSize(for category: PrivacyCategory, browser: Browser) async throws -> Int64 {
        try await worker.previewSize(for: category, browser: browser)
    }

    /// All on-disk paths the provider knows about for `(browser, category)`.
    /// Used by `PrivacyViewModel` to dedupe URLs across selected categories
    /// (Chromium / Firefox `.history` and `.downloads` share a SQLite file).
    func paths(for category: PrivacyCategory, browser: Browser) -> [URL] {
        pathProvider.dataPaths(for: browser, category: category)
    }

    /// Remove every existing path for `(browser, category)`. Throws on the
    /// first remover failure; missing paths are silently skipped.
    func clear(category: PrivacyCategory, browser: Browser) async throws {
        try await worker.clear(category: category, browser: browser)
    }
}

/// Serializes browser-data filesystem work away from the main actor.
/// `FileManager` calls here are synchronous, so isolating them to this
/// actor keeps Privacy view-model orchestration responsive while also
/// giving repeated scans / clears one cooperative cancellation path.
private actor BrowserDataWorker {

    private let pathProvider: BrowserDataPathProviding
    private let fileManager: FileManager
    private let remover: BrowserDataClearer.Remover
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "BrowserDataClearer")

    init(
        pathProvider: BrowserDataPathProviding,
        fileManager: FileManager,
        remover: BrowserDataClearer.Remover?
    ) {
        self.pathProvider = pathProvider
        self.fileManager = fileManager
        self.remover = remover ?? { url in
            try fileManager.removeItem(at: url)
        }
    }

    func previewSize(for category: PrivacyCategory, browser: Browser) throws -> Int64 {
        try Task.checkCancellation()
        let paths = pathProvider.dataPaths(for: browser, category: category)
        return try paths.reduce(into: Int64(0)) { acc, url in
            try Task.checkCancellation()
            acc += try sizeOnDisk(at: url)
        }
    }

    func clear(category: PrivacyCategory, browser: Browser) throws {
        try Task.checkCancellation()
        let paths = pathProvider.dataPaths(for: browser, category: category)
        for url in paths {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: url.path) else {
                log.debug("Skipping missing path: \(url.path, privacy: .public)")
                continue
            }
            try remover(url)
        }
    }

    // MARK: - Sizing

    /// Recursive byte count for `url`. Returns 0 for missing paths or paths
    /// the process can't read. Directories enumerate via
    /// `FileManager.enumerator` with file-size + directory keys so the walk
    /// runs in one pass without a separate stat for every entry.
    private func sizeOnDisk(at url: URL) throws -> Int64 {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: url.path) else { return 0 }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let isDirectory = values?.isDirectory ?? false

        if !isDirectory {
            return Int64(values?.fileSize ?? 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let entry as URL in enumerator {
            try Task.checkCancellation()
            if let entryValues = try? entry.resourceValues(forKeys: resourceKeys),
               entryValues.isDirectory == false {
                total += Int64(entryValues.fileSize ?? 0)
            }
        }
        return total
    }
}
