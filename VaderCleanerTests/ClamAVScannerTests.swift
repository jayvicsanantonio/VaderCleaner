// ClamAVScannerTests.swift
// Verifies ClamAVScanner builds correct clamscan arguments, streams progress, treats exit 0/1 as success, and throws on hard errors or a missing binary.

import XCTest
@testable import VaderCleaner

final class ClamAVScannerTests: XCTestCase {

    private let binary = URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")

    func test_scan_buildsRecursiveInfectedNoSummaryArgumentsWithPaths() async throws {
        // No database provider here — verify the base argument list when
        // clamscan should fall back to its compiled-in DB directory.
        var capturedExecutable: URL?
        var capturedArguments: [String]?
        let scanner = makeScanner(installed: true, databaseDirectory: nil) {
            executable, arguments, _ in
            capturedExecutable = executable
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x"), URL(fileURLWithPath: "/tmp/y")],
            progress: { _ in }
        )

        XCTAssertEqual(capturedExecutable, binary)
        XCTAssertEqual(
            capturedArguments,
            ["--recursive", "--infected", "--no-summary", "/Users/x", "/tmp/y"]
        )
    }

    func test_scan_prependsDatabaseArgumentWhenProviderReturnsAURL() async throws {
        // The bundled clamscan's compiled-in default DB path is the
        // Homebrew Cellar — absent on a user machine. `--database` must
        // point at the directory freshclam populated under Application
        // Support, ahead of the rest of the arguments so the override is
        // unambiguous.
        let dbDirectory = URL(fileURLWithPath: "/Users/x/Library/Application Support/VaderCleaner/clamav/db")
        var capturedArguments: [String]?
        let scanner = makeScanner(installed: true, databaseDirectory: dbDirectory) {
            _, arguments, _ in
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _ in }
        )

        XCTAssertEqual(
            capturedArguments,
            ["--database=\(dbDirectory.path)",
             "--recursive", "--infected", "--no-summary",
             "/Users/x"]
        )
    }

    func test_scan_returnsEmptyAndForwardsProgressOnCleanExitZero() async throws {
        var progressLines: [String] = []
        let scanner = makeScanner(installed: true) { _, _, onLine in
            onLine("Scanning /Users/x/a.txt")
            onLine("/Users/x/a.txt: OK")
            return 0
        }

        let threats = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { progressLines.append($0) }
        )

        XCTAssertTrue(threats.isEmpty)
        XCTAssertEqual(progressLines, ["Scanning /Users/x/a.txt", "/Users/x/a.txt: OK"])
    }

    func test_scan_parsesThreatsOnExitOne() async throws {
        // clamscan exits 1 when at least one infected file is found — this is
        // a successful scan with results, NOT a failure.
        let scanner = makeScanner(installed: true) { _, _, onLine in
            onLine("/Users/x/evil.bin: Eicar-Test-Signature FOUND")
            return 1
        }

        let threats = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _ in }
        )

        XCTAssertEqual(threats.count, 1)
        XCTAssertEqual(threats[0].threatName, "Eicar-Test-Signature")
        XCTAssertEqual(threats[0].filePath, URL(fileURLWithPath: "/Users/x/evil.bin"))
    }

    func test_scan_throwsOnHardErrorExitTwo() async {
        let scanner = makeScanner(installed: true) { _, _, _ in 2 }
        do {
            _ = try await scanner.scan(
                paths: [URL(fileURLWithPath: "/Users/x")],
                progress: { _ in }
            )
            XCTFail("Expected scan() to throw on clamscan exit code 2")
        } catch {
            // Expected.
        }
    }

    func test_scan_throwsWhenClamAVNotInstalled() async {
        let scanner = makeScanner(installed: false) { _, _, _ in 0 }
        do {
            _ = try await scanner.scan(
                paths: [URL(fileURLWithPath: "/Users/x")],
                progress: { _ in }
            )
            XCTFail("Expected scan() to throw when clamscan is absent")
        } catch {
            // Expected.
        }
    }

    // MARK: - Helpers

    private func makeScanner(
        installed: Bool,
        databaseDirectory: URL? = nil,
        runner: @escaping ClamAVScanner.ScanRunner
    ) -> ClamAVScanner {
        let detector = ClamAVDetector(
            candidatePaths: [binary],
            isExecutable: { _ in installed },
            versionRunner: { _ in nil }
        )
        // Default to no database directory so tests run hermetically —
        // the production default reaches into ~/Library/Application
        // Support, which would couple unit tests to the host filesystem.
        return ClamAVScanner(
            detector: detector,
            runner: runner,
            databaseDirectoryProvider: { databaseDirectory }
        )
    }
}
