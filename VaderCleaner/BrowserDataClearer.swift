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
struct BrowserDataClearer: Sendable {

    typealias Remover = @Sendable (URL) throws -> Void

    private let pathProvider: BrowserDataPathProviding
    private let worker: BrowserDataWorker

    init(
        pathProvider: BrowserDataPathProviding,
        remover: Remover? = nil
    ) {
        self.pathProvider = pathProvider
        self.worker = BrowserDataWorker(
            pathProvider: pathProvider,
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
    /// The shared instance, documented as safe across threads. Held directly
    /// rather than injected: no caller or test ever supplied a different one.
    private let fileManager = FileManager.default
    private let remover: BrowserDataClearer.Remover
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "BrowserDataClearer")

    init(
        pathProvider: BrowserDataPathProviding,
        remover: BrowserDataClearer.Remover?
    ) {
        self.pathProvider = pathProvider
        // References the shared instance rather than capturing the actor's
        // stored one, so the default remover stays a plain `@Sendable` closure.
        self.remover = remover ?? { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    func previewSize(for category: PrivacyCategory, browser: Browser) throws -> Int64 {
        try Task.checkCancellation()
        let paths = pathProvider.dataPaths(for: browser, category: category)
        return try paths.reduce(into: Int64(0)) { acc, url in
            try Task.checkCancellation()
            // The checkpoint keeps a large profile tree interruptible
            // mid-directory rather than only between paths.
            acc += try PathSizer.size(
                at: url,
                fileManager: fileManager,
                checkpoint: Task.checkCancellation
            )
        }
    }

    func clear(category: PrivacyCategory, browser: Browser) throws {
        try Task.checkCancellation()
        let paths = pathProvider.dataPaths(for: browser, category: category)
        for url in paths {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: url.path) else {
                log.debug("Skipping missing path: \(url.path, privacy: .private)")
                continue
            }
            try remover(url)
        }
    }
}
