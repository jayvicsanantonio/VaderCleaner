// BrowserDataClearerTests.swift
// Verifies that BrowserDataClearer correctly sums on-disk byte sizes for a (browser, category) pair, removes every existing path on clear, and tolerates missing paths without error.

import XCTest
@testable import VaderCleaner

final class BrowserDataClearerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - previewSize

    /// `previewSize` walks every path returned by the provider and sums up
    /// the on-disk bytes — files contribute their size, directories
    /// contribute the recursive total. The clearer's contract with the UI
    /// is "show what we'd actually free", so a wrong total here misleads
    /// the user about how much the action will reclaim.
    func test_previewSize_sumsBytesAcrossFilesAndDirectories() throws {
        let history = try TestHelpers.createDummyFile(named: "History.db", size: 100, in: tempRoot)
        let cacheDir = tempRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 3, size: 50, in: cacheDir) // 150 bytes total

        let provider = StubProvider(paths: [.history: [history, cacheDir]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        let bytes = clearer.previewSize(for: .history, browser: .chrome)
        XCTAssertEqual(bytes, 100 + 150)
    }

    /// Missing paths must not crash or throw — every browser-data path is
    /// optional in practice (e.g. the user never used cookies), so a
    /// non-existent path simply contributes 0 to the total.
    func test_previewSize_returnsZeroForMissingPaths() {
        let bogus = tempRoot.appendingPathComponent("does-not-exist")
        let provider = StubProvider(paths: [.cookies: [bogus]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        XCTAssertEqual(clearer.previewSize(for: .cookies, browser: .chrome), 0)
    }

    /// When the provider returns no paths (e.g. Firefox without a profile
    /// yet) the size must be 0 with no I/O at all.
    func test_previewSize_returnsZeroForEmptyProviderResult() {
        let provider = StubProvider(paths: [:])
        let clearer = BrowserDataClearer(pathProvider: provider)
        XCTAssertEqual(clearer.previewSize(for: .history, browser: .firefox), 0)
    }

    // MARK: - clear

    /// `clear` must remove every path the provider returns. Files and
    /// directories alike — the clearer doesn't try to be selective inside a
    /// directory because the whole point of a "Clear Cache" action is to
    /// drop the lot.
    func test_clear_removesEveryExistingPath() throws {
        let history = try TestHelpers.createDummyFile(named: "History.db", size: 100, in: tempRoot)
        let cacheDir = tempRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "page1", size: 50, in: cacheDir)

        let provider = StubProvider(paths: [.history: [history, cacheDir]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        try clearer.clear(category: .history, browser: .chrome)

        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path))
    }

    /// `clear` must tolerate missing paths so a partially-populated browser
    /// (e.g. cookies file exists but cache dir doesn't) doesn't raise an
    /// error mid-clear and leave the user staring at a misleading "couldn't
    /// finish" message when, in fact, everything reachable was cleared.
    func test_clear_silentlySkipsMissingPaths() throws {
        let bogus = tempRoot.appendingPathComponent("does-not-exist")
        let real = try TestHelpers.createDummyFile(named: "Cookies", size: 50, in: tempRoot)

        let provider = StubProvider(paths: [.cookies: [bogus, real]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        XCTAssertNoThrow(try clearer.clear(category: .cookies, browser: .chrome))
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path),
                       "Real cookies file should be removed even when sibling path is missing")
    }

    /// When `clear` actually fails (permission error, locked file), the
    /// error must surface so the view-model can transition to `.failed`.
    /// Suppressing it would leave the UI claiming "Cleared" when nothing
    /// happened.
    func test_clear_throwsWhenInjectedRemoverThrows() {
        let real = tempRoot.appendingPathComponent("Cookies")
        FileManager.default.createFile(atPath: real.path, contents: Data(repeating: 0, count: 8))

        let provider = StubProvider(paths: [.cookies: [real]])
        let clearer = BrowserDataClearer(
            pathProvider: provider,
            remover: { _ in throw FailingRemoverError.boom }
        )

        XCTAssertThrowsError(try clearer.clear(category: .cookies, browser: .chrome)) { error in
            XCTAssertTrue(error is FailingRemoverError)
        }
    }

    // MARK: - Stubs

    /// In-memory provider keyed by category, ignoring the browser argument
    /// — the clearer's behavior is browser-agnostic; the path provider is
    /// what knows the difference. Driving every test with one provider per
    /// category keeps fixtures small.
    private struct StubProvider: BrowserDataPathProviding {
        let paths: [PrivacyCategory: [URL]]

        func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
            paths[category] ?? []
        }
    }

    private enum FailingRemoverError: Error {
        case boom
    }
}
