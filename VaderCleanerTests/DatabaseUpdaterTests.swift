// DatabaseUpdaterTests.swift
// Verifies DatabaseUpdater reports the newest signature-file mtime and routes update() through an injected freshclam runner.

import XCTest
@testable import VaderCleaner

final class DatabaseUpdaterTests: XCTestCase {

    private var dbDir: URL!

    override func setUpWithError() throws {
        dbDir = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(dbDir)
    }

    // MARK: - lastUpdateDate

    func test_lastUpdateDate_isNilWhenNoSignatureFilesPresent() {
        let updater = makeUpdater()
        XCTAssertNil(updater.lastUpdateDate())
    }

    func test_lastUpdateDate_returnsNewestSignatureFileModificationDate() throws {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let recent = Date(timeIntervalSince1970: 1_700_000_000)

        try writeSignatureFile(named: "main.cvd", modified: old)
        try writeSignatureFile(named: "daily.cld", modified: recent)
        try writeSignatureFile(named: "bytecode.cvd", modified: old)

        let updater = makeUpdater()
        let date = try XCTUnwrap(updater.lastUpdateDate())
        XCTAssertEqual(date.timeIntervalSince1970, recent.timeIntervalSince1970, accuracy: 1.0)
    }

    func test_lastUpdateDate_ignoresUnrelatedFiles() throws {
        try writeSignatureFile(named: "freshclam.log", modified: Date())
        let updater = makeUpdater()
        XCTAssertNil(updater.lastUpdateDate())
    }

    func test_lastUpdateDate_considersNonStandardSignatureDatabases() throws {
        // freshclam also maintains optional databases (e.g. safebrowsing,
        // third-party feeds) — a fixed filename list would miss these and
        // report a stale timestamp.
        let recent = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSignatureFile(named: "main.cvd", modified: Date(timeIntervalSince1970: 1_600_000_000))
        try writeSignatureFile(named: "safebrowsing.cld", modified: recent)

        let date = try XCTUnwrap(makeUpdater().lastUpdateDate())
        XCTAssertEqual(date.timeIntervalSince1970, recent.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - update

    func test_update_invokesFreshclamRunnerAndForwardsProgress() async throws {
        let capturedExecutable = TestBox<URL?>(nil)
        let lines = TestBox<[String]>([])
        let updater = DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in true },
            runner: { executable, onLine in
                capturedExecutable.value = executable
                onLine("Downloading daily.cvd")
                onLine("daily.cvd updated")
                return 0
            }
        )

        try await updater.update { lines.value.append($0) }

        XCTAssertEqual(capturedExecutable.value?.path, "/opt/homebrew/bin/freshclam")
        XCTAssertEqual(lines.value, ["Downloading daily.cvd", "daily.cvd updated"])
    }

    func test_update_throwsOnNonZeroExit() async {
        let updater = DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in true },
            runner: { _, _ in 1 }
        )
        do {
            try await updater.update()
            XCTFail("Expected update() to throw on non-zero freshclam exit")
        } catch {
            // Expected.
        }
    }

    func test_update_throwsWhenFreshclamNotInstalled() async {
        let updater = DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in false },
            runner: { _, _ in 0 }
        )
        do {
            try await updater.update()
            XCTFail("Expected update() to throw when freshclam is absent")
        } catch {
            // Expected.
        }
    }

    // MARK: - refreshIfStale

    func test_refreshIfStale_updatesWhenNoSignaturesArePresent() async {
        // No signatures at all means the scan would run against nothing, so
        // this is the case that most needs a refresh.
        let ran = TestBox(false)
        let updater = makeUpdater(runner: { _, _ in ran.value = true; return 0 })

        let refreshed = await updater.refreshIfStale()

        XCTAssertTrue(ran.value)
        XCTAssertTrue(refreshed)
    }

    func test_refreshIfStale_updatesWhenSignaturesAreOlderThanMaxAge() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSignatureFile(named: "daily.cld", modified: now.addingTimeInterval(-DatabaseUpdater.maxAge - 60))
        let ran = TestBox(false)
        let updater = makeUpdater(runner: { _, _ in ran.value = true; return 0 })

        let refreshed = await updater.refreshIfStale(now: now)

        XCTAssertTrue(ran.value)
        XCTAssertTrue(refreshed)
    }

    func test_refreshIfStale_leavesFreshSignaturesAlone() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSignatureFile(named: "daily.cld", modified: now.addingTimeInterval(-60))
        let ran = TestBox(false)
        let updater = makeUpdater(runner: { _, _ in ran.value = true; return 0 })

        let refreshed = await updater.refreshIfStale(now: now)

        XCTAssertFalse(ran.value, "a database inside maxAge must not pay for a freshclam run")
        XCTAssertFalse(refreshed)
    }

    func test_refreshIfStale_swallowsAFailedUpdateSoTheScanCanStillRun() async {
        // Losing the whole malware result because freshclam couldn't reach the
        // network is worse than scanning against the signatures already on disk.
        let updater = makeUpdater(runner: { _, _ in 1 })

        let refreshed = await updater.refreshIfStale()

        XCTAssertFalse(refreshed)
    }

    func test_refreshIfStale_swallowsAMissingFreshclam() async {
        let updater = DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in false },
            runner: { _, _ in 0 }
        )

        let refreshed = await updater.refreshIfStale()

        XCTAssertFalse(refreshed)
    }

    // MARK: - Helpers

    private func makeUpdater(
        runner: @escaping DatabaseUpdater.FreshclamRunner = { _, _ in 0 }
    ) -> DatabaseUpdater {
        DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in true },
            runner: runner
        )
    }

    private func writeSignatureFile(named name: String, modified: Date) throws {
        let url = dbDir.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
    }
}
