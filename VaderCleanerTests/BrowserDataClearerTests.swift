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
    func test_previewSize_sumsBytesAcrossFilesAndDirectories() async throws {
        let history = try TestHelpers.createDummyFile(named: "History.db", size: 100, in: tempRoot)
        let cacheDir = tempRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 3, size: 50, in: cacheDir) // 150 bytes total

        let provider = StubProvider(paths: [.history: [history, cacheDir]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        let bytes = try await clearer.previewSize(for: .history, browser: .chrome)
        XCTAssertEqual(bytes, 100 + 150)
    }

    /// Missing paths must not crash or throw — every browser-data path is
    /// optional in practice (e.g. the user never used cookies), so a
    /// non-existent path simply contributes 0 to the total.
    func test_previewSize_returnsZeroForMissingPaths() async throws {
        let bogus = tempRoot.appendingPathComponent("does-not-exist")
        let provider = StubProvider(paths: [.cookies: [bogus]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        let bytes = try await clearer.previewSize(for: .cookies, browser: .chrome)
        XCTAssertEqual(bytes, 0)
    }

    /// When the provider returns no paths (e.g. Firefox without a profile
    /// yet) the size must be 0 with no I/O at all.
    func test_previewSize_returnsZeroForEmptyProviderResult() async throws {
        let provider = StubProvider(paths: [:])
        let clearer = BrowserDataClearer(pathProvider: provider)
        let bytes = try await clearer.previewSize(for: .history, browser: .firefox)
        XCTAssertEqual(bytes, 0)
    }

    /// Cancellation must interrupt large recursive sizing walks so a
    /// restarted Privacy preview doesn't keep burning I/O in the background.
    func test_previewSize_honorsCancellationDuringDirectoryWalk() async throws {
        let cacheDir = tempRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 1_000, size: 1, in: cacheDir)

        let provider = StubProvider(paths: [.cache: [cacheDir]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        let task = Task {
            try await clearer.previewSize(for: .cache, browser: .chrome)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - clear

    /// `clear` must remove every path the provider returns. Files and
    /// directories alike — the clearer doesn't try to be selective inside a
    /// directory because the whole point of a "Clear Cache" action is to
    /// drop the lot.
    func test_clear_removesEveryExistingPath() async throws {
        let history = try TestHelpers.createDummyFile(named: "History.db", size: 100, in: tempRoot)
        let cacheDir = tempRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "page1", size: 50, in: cacheDir)

        let provider = StubProvider(paths: [.history: [history, cacheDir]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        try await clearer.clear(category: .history, browser: .chrome)

        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path))
    }

    /// **Deliberate inversion of plan.md Prompt 26 — see issue #38 / #75.**
    ///
    /// Privacy is a targeted "clear my browser data" action, not a broad
    /// safe-defaults sweep. Applying the user's general exclusions list
    /// here would silently leave behind data the user explicitly asked to
    /// clear. So `BrowserDataClearer` intentionally does **not** consult
    /// `ExclusionsStore`: a path being on the exclusions list must not stop
    /// it from being cleared. This test locks that contract in so a future
    /// change can't re-wire exclusions into Privacy without consciously
    /// deleting this assertion.
    @MainActor
    func test_clear_ignoresExclusionsByDesign() async throws {
        let history = try TestHelpers.createDummyFile(
            named: "History.db",
            size: 100,
            in: tempRoot
        )

        // Put the very path we're about to clear on the exclusions list.
        // Isolated suite so the test never touches the user's real
        // UserDefaults.
        let suiteName = "BrowserDataClearerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let exclusions = ExclusionsStore(defaults: defaults)
        exclusions.add(path: history.path)
        XCTAssertTrue(
            exclusions.exclusions.contains { history.path.hasPrefix($0) },
            "Precondition: the path must actually be on the exclusions list"
        )

        let provider = StubProvider(paths: [.history: [history]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        try await clearer.clear(category: .history, browser: .chrome)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: history.path),
            "Privacy must clear data even when its path is excluded — exclusions are intentionally not consulted here (issue #38)"
        )
    }

    /// `clear` must tolerate missing paths so a partially-populated browser
    /// (e.g. cookies file exists but cache dir doesn't) doesn't raise an
    /// error mid-clear and leave the user staring at a misleading "couldn't
    /// finish" message when, in fact, everything reachable was cleared.
    func test_clear_silentlySkipsMissingPaths() async throws {
        let bogus = tempRoot.appendingPathComponent("does-not-exist")
        let real = try TestHelpers.createDummyFile(named: "Cookies", size: 50, in: tempRoot)

        let provider = StubProvider(paths: [.cookies: [bogus, real]])
        let clearer = BrowserDataClearer(pathProvider: provider)

        do {
            try await clearer.clear(category: .cookies, browser: .chrome)
        } catch {
            XCTFail("Expected missing paths to be skipped, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path),
                       "Real cookies file should be removed even when sibling path is missing")
    }

    /// When `clear` actually fails (permission error, locked file), the
    /// error must surface so the view-model can transition to `.failed`.
    /// Suppressing it would leave the UI claiming "Cleared" when nothing
    /// happened.
    func test_clear_throwsWhenInjectedRemoverThrows() async {
        let real = tempRoot.appendingPathComponent("Cookies")
        FileManager.default.createFile(atPath: real.path, contents: Data(repeating: 0, count: 8))

        let provider = StubProvider(paths: [.cookies: [real]])
        let clearer = BrowserDataClearer(
            pathProvider: provider,
            remover: { _ in throw FailingRemoverError.boom }
        )

        do {
            try await clearer.clear(category: .cookies, browser: .chrome)
            XCTFail("Expected injected remover to throw")
        } catch {
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
