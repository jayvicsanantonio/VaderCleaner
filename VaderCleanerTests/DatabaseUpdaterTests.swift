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

    // MARK: - update

    func test_update_invokesFreshclamRunnerAndForwardsProgress() async throws {
        var capturedExecutable: URL?
        var lines: [String] = []
        let updater = DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in true },
            runner: { executable, onLine in
                capturedExecutable = executable
                onLine("Downloading daily.cvd")
                onLine("daily.cvd updated")
                return 0
            }
        )

        try await updater.update { lines.append($0) }

        XCTAssertEqual(capturedExecutable?.path, "/opt/homebrew/bin/freshclam")
        XCTAssertEqual(lines, ["Downloading daily.cvd", "daily.cvd updated"])
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

    // MARK: - Helpers

    private func makeUpdater() -> DatabaseUpdater {
        DatabaseUpdater(
            databaseDirectories: [dbDir],
            freshclamPaths: [URL(fileURLWithPath: "/opt/homebrew/bin/freshclam")],
            isExecutable: { _ in true },
            runner: { _, _ in 0 }
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
