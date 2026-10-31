// ClamAVScannerCoverageTests.swift
// Pins what a scan may conclude from clamscan's exit status: an unreadable file doesn't fail a scan, a hard error does, and an infection clamscan reported is never turned into a clean result.

import CryptoKit
import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct ClamAVScannerCoverageTests {

    private static let binary = URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")
    private static let home = URL(fileURLWithPath: "/Users/me")

    private func makeScanner(
        runner: @escaping ClamAVScanner.ScanRunner,
        newlinePaths: @escaping ClamAVScanner.NewlinePathFinder = { _ in [] }
    ) -> ClamAVScanner {
        ClamAVScanner(
            detector: ClamAVDetector(
                candidatePaths: [Self.binary],
                isExecutable: { _ in true },
                versionRunner: { _ in nil }
            ),
            runner: runner,
            databaseDirectoryProvider: { nil },
            excludedDirectories: [],
            progressThrottleInterval: 0,
            isRegularFile: { _ in true },
            newlinePathFinder: newlinePaths,
            selfTestsEngine: false
        )
    }

    // MARK: - Unreadable files

    @Test
    func unreadableFileDoesNotFailACleanScan() async throws {
        let scanner = makeScanner(runner: { _, _, onLine in
            onLine("/Users/me/ok.txt: OK")
            onLine("/Users/me/locked.txt: Access denied")
            onLine("/Users/me/lockeddir: Can't open directory.")
            return 2
        })

        let report = try await scanner.scanReport(paths: [Self.home], progress: { _, _ in })

        #expect(report.threats.isEmpty)
        #expect(report.unreadableCount == 2)
    }

    @Test
    func exitTwoWithoutARecognisedLineStillReportsMissedCoverage() async throws {
        let scanner = makeScanner(runner: { _, _, onLine in
            onLine("/Users/me/ok.txt: OK")
            return 2
        })

        let report = try await scanner.scanReport(paths: [Self.home], progress: { _, _ in })

        #expect(report.unreadableCount == 1, "clamscan said it hit an error, so the scan can't read as complete")
    }

    @Test
    func aPlantedLineCannotClaimMissedCoverageOnACompleteScan() async throws {
        let scanner = makeScanner(runner: { _, _, onLine in
            onLine("/Users/me/x: Access denied")
            return 0
        })

        let report = try await scanner.scanReport(paths: [Self.home], progress: { _, _ in })

        #expect(report.unreadableCount == 0, "exit 0 means every file was read")
    }

    @Test
    func hardErrorBeforeAnyFileFailsTheScan() async throws {
        let scanner = makeScanner(runner: { _, _, _ in 2 })

        await #expect(throws: ClamAVEngineError.scanFailed) {
            _ = try await scanner.scanReport(paths: [Self.home], progress: { _, _ in })
        }
    }

    @Test
    func unreadableFileBesideAThreatIsCountedToo() async throws {
        let sample = "/Users/me/sample.bin"
        let scanner = makeScanner(runner: { _, arguments, onLine in
            onLine("\(sample): Eicar-Test-Signature FOUND")
            if arguments.contains("--recursive") { onLine("/Users/me/locked.txt: Access denied") }
            return 1
        })

        let report = try await scanner.scanReport(paths: [Self.home], progress: { _, _ in })

        #expect(report.threats.map(\.filePath.path) == [sample])
        #expect(report.unreadableCount == 1)
    }

    // MARK: - Infections that can't be parsed from one line

    @Test
    func infectedFileWithANewlineInItsNameIsFound() async throws {
        let evil = "/Users/me/evil\npayload"
        let scanner = makeScanner(
            runner: { _, arguments, onLine in
                if arguments.contains("--recursive") {
                    onLine("/Users/me/evil")
                    onLine("payload: Osx.Malware.Agent-1 FOUND")
                    return 1
                }
                #expect(arguments.last == evil)
                onLine("/Users/me/evil")
                onLine("payload: Osx.Malware.Agent-1 FOUND")
                return 1
            },
            newlinePaths: { _ in [URL(fileURLWithPath: evil)] }
        )

        let threats = try await scanner.scan(paths: [Self.home], progress: { _, _ in })

        #expect(threats == [MalwareThreat(filePath: URL(fileURLWithPath: evil), threatName: "Osx.Malware.Agent-1")])
    }

    @Test
    func aCleanFileWithANewlineInItsNameIsNotReported() async throws {
        let sample = "/Users/me/sample.bin"
        let clean = "/Users/me/notes\nold.txt"
        let scanner = makeScanner(
            runner: { _, arguments, onLine in
                if arguments.contains("--recursive") {
                    onLine("\(sample): Eicar-Test-Signature FOUND")
                    onLine("forged: Win.Trojan.Fake-1 FOUND")
                    return 1
                }
                if arguments.last == clean {
                    onLine("/Users/me/notes")
                    onLine("old.txt: OK")
                    return 0
                }
                onLine("\(sample): Eicar-Test-Signature FOUND")
                return 1
            },
            newlinePaths: { _ in [URL(fileURLWithPath: clean)] }
        )

        let threats = try await scanner.scan(paths: [Self.home], progress: { _, _ in })

        #expect(threats.map(\.filePath.path) == [sample], "only the exit status of a run over that one file counts")
    }

    @Test
    func anInfectionNobodyCanLocateIsNotReportedAsClean() async throws {
        let scanner = makeScanner(runner: { _, _, onLine in
            onLine("payload: Osx.Malware.Agent-1 FOUND")
            return 1
        })

        await #expect(throws: ClamAVEngineError.unlocatedInfection) {
            _ = try await scanner.scan(paths: [Self.home], progress: { _, _ in })
        }
    }

    @Test
    func theNewlineSearchRunsOnlyWhenAVerdictIsUnaccountedFor() async throws {
        let searched = TestBox(false)
        let sample = "/Users/me/sample.bin"
        let scanner = makeScanner(
            runner: { _, _, onLine in
                onLine("\(sample): Eicar-Test-Signature FOUND")
                return 1
            },
            newlinePaths: { _ in
                searched.value = true
                return []
            }
        )

        _ = try await scanner.scan(paths: [Self.home], progress: { _, _ in })

        #expect(!searched.value, "walking the whole home folder is only worth it when something is missing")
    }

    @Test
    func theDefaultSearchFindsOnlyRegularFilesWithANewlineInTheirPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("NewlineFinder-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let nestedDirectory = root.appendingPathComponent("x\ny", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let inNamedFile = root.appendingPathComponent("evil\npayload")
        let inNamedDirectory = nestedDirectory.appendingPathComponent("inner.bin")
        try Data("a".utf8).write(to: inNamedFile)
        try Data("a".utf8).write(to: inNamedDirectory)
        try Data("a".utf8).write(to: root.appendingPathComponent("plain.txt"))

        let found = ClamAVScanner.defaultNewlinePathFinder([root]).map(\.lastPathComponent).sorted()

        #expect(found == ["evil\npayload", "inner.bin"].sorted())
    }

    // MARK: - Error wording

    @Test(arguments: [ClamAVEngineError.notInstalled, .scanFailed, .unlocatedInfection, .selfTestFailed])
    func engineErrorsNeverNameAToolOrExitStatus(error: ClamAVEngineError) throws {
        let message = try #require(error.errorDescription)
        #expect(!message.contains("clamscan"))
        #expect(!message.contains("exited"))
    }

    // MARK: - Cloud placeholders

    @Test
    func everyWholeHomeScanSkipsOnlineOnlyCloudFiles() {
        for mode in [ScanMode.balanced, .deep] {
            let scope = MalwareViewModel.scanScope(for: mode, excludeICloud: true)
            #expect(scope.excludedDirectories.contains("/Library/CloudStorage/"))
        }
    }
}

/// Runs the real bundled `clamscan`, which `Scripts/bundle-clamav.sh` stages
/// into `Vendor/clamav`, against the cases its exit status decides.
@Suite
struct ClamAVScannerCoverageIntegrationTests {

    private static let vendor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // VaderCleanerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // VaderCleanerCore
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("Vendor/clamav")
    private static let clamscan = vendor.appendingPathComponent("bin/clamscan")
    private static let certs = vendor.appendingPathComponent("certs")
    private static let payload = Data("VaderCleaner ClamAV coverage fixture".utf8)

    private func stage() throws -> (workspace: URL, tree: URL, database: URL) {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("ClamAVScannerCoverage-\(UUID().uuidString)")
        let tree = workspace.appendingPathComponent("tree")
        let database = workspace.appendingPathComponent("db")
        try fileManager.createDirectory(at: tree, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: database, withIntermediateDirectories: true)
        let md5 = Insecure.MD5.hash(data: Self.payload).map { String(format: "%02x", $0) }.joined()
        try Data("\(md5):\(Self.payload.count):VaderCleaner.Test.Fixture\n".utf8)
            .write(to: database.appendingPathComponent("test.hdb"))
        return (workspace, tree, database)
    }

    private func scanner(database: URL) -> ClamAVScanner {
        let certs = Self.certs
        return ClamAVScanner(
            detector: ClamAVDetector(candidatePaths: [Self.clamscan], versionRunner: { _ in nil }),
            runner: { executable, arguments, onLine in
                var environment = ProcessInfo.processInfo.environment
                environment["CVD_CERTS_DIR"] = certs.path
                return try await ProcessLineStreamer.run(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    onLine: onLine
                )
            },
            databaseDirectoryProvider: { database },
            excludedDirectories: []
        )
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: clamscan.path)))
    func unreadableFileLeavesACleanScanStandingAndCounted() async throws {
        let (workspace, tree, database) = try stage()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: workspace) }
        try Data("clean".utf8).write(to: tree.appendingPathComponent("ok.txt"))
        let locked = tree.appendingPathComponent("locked.txt")
        try Data("clean".utf8).write(to: locked)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let report = try await scanner(database: database).scanReport(paths: [tree], progress: { _, _ in })

        #expect(report.threats.isEmpty)
        #expect(report.unreadableCount == 1)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: clamscan.path)))
    func infectedFileWithANewlineInItsNameIsFound() async throws {
        let (workspace, tree, database) = try stage()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let evil = tree.appendingPathComponent("evil\npayload")
        try Self.payload.write(to: evil)

        let threats = try await scanner(database: database).scan(paths: [tree], progress: { _, _ in })

        #expect(threats.map(\.filePath.lastPathComponent) == ["evil\npayload"])
        #expect(threats.map(\.threatName) == ["VaderCleaner.Test.Fixture.UNOFFICIAL"])
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: clamscan.path)))
    func anEmptyDatabaseFailsTheScanInsteadOfReadingAsClean() async throws {
        let (workspace, tree, _) = try stage()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("clean".utf8).write(to: tree.appendingPathComponent("ok.txt"))
        let empty = workspace.appendingPathComponent("empty-db")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        await #expect(throws: ClamAVEngineError.scanFailed) {
            _ = try await scanner(database: empty).scanReport(paths: [tree], progress: { _, _ in })
        }
    }
}
