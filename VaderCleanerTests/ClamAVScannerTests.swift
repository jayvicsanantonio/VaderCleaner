// ClamAVScannerTests.swift
// Verifies ClamAVScanner builds correct clamscan arguments, streams progress, treats exit 0/1 as success, and throws on hard errors or a missing binary.

import XCTest
@testable import VaderCleaner

final class ClamAVScannerTests: XCTestCase {

    private let binary = URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")

    func test_scan_buildsRecursiveNoSummaryArgumentsWithPaths() async throws {
        // No database provider, no exclusions — verify the base argument
        // list when clamscan falls back to its compiled-in defaults.
        // `--infected` is intentionally *not* in the list: with it,
        // clamscan stays silent during clean stretches and the UI has no
        // progress signal to display. We parse `FOUND` separately so
        // dropping the flag doesn't change threat detection.
        var capturedExecutable: URL?
        var capturedArguments: [String]?
        let scanner = makeScanner(installed: true,
                                  databaseDirectory: nil,
                                  excludedDirectories: []) {
            executable, arguments, _ in
            capturedExecutable = executable
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x"), URL(fileURLWithPath: "/tmp/y")],
            progress: { _, _ in }
        )

        XCTAssertEqual(capturedExecutable, binary)
        XCTAssertEqual(
            capturedArguments,
            ["--recursive", "--no-summary", "/Users/x", "/tmp/y"]
        )
    }

    func test_scan_appendsExcludeDirArgumentsBeforeScanPaths() async throws {
        // Exclusions are full Perl-compatible regexes against clamscan's
        // candidate directory paths; we feed them as `--exclude-dir=<re>`
        // ahead of the scan targets so the override is unambiguous.
        var capturedArguments: [String]?
        let scanner = makeScanner(
            installed: true,
            databaseDirectory: nil,
            excludedDirectories: ["/node_modules/", "/\\.git/"]
        ) { _, arguments, _ in
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _, _ in }
        )

        XCTAssertEqual(
            capturedArguments,
            [
                "--exclude-dir=/node_modules/",
                "--exclude-dir=/\\.git/",
                "--recursive", "--no-summary",
                "/Users/x"
            ]
        )
    }

    func test_scan_defaultOptionsAddNoScanContentFlags() async throws {
        // The default ScanOptions mirrors clamscan's own defaults (mail and
        // archives inspected), so a default-constructed value must add no
        // `--scan-*` flags — keeping the base argument list minimal.
        var capturedArguments: [String]?
        let scanner = makeScanner(installed: true,
                                  databaseDirectory: nil,
                                  excludedDirectories: []) { _, arguments, _ in
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _, _ in }
        )

        XCTAssertEqual(capturedArguments, ["--recursive", "--no-summary", "/Users/x"])
    }

    func test_scan_appendsDisableFlagsWhenScanContentOptionsAreOff() async throws {
        // Turning the Protection content options off must emit explicit
        // `--scan-mail=no` / `--scan-archive=no` ahead of the scan paths.
        var capturedArguments: [String]?
        let scanner = makeScanner(installed: true,
                                  databaseDirectory: nil,
                                  excludedDirectories: []) { _, arguments, _ in
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            options: ClamAVScanner.ScanOptions(scanMail: false, scanArchives: false),
            progress: { _, _ in }
        )

        XCTAssertEqual(
            capturedArguments,
            ["--recursive", "--no-summary", "--scan-mail=no", "--scan-archive=no", "/Users/x"]
        )
    }

    func test_scan_throttlesProgressCallbackToConfiguredInterval() async throws {
        // The runner closure is invoked once per output line by
        // ProcessLineStreamer. On a clean machine that's millions of
        // lines; without throttling each one would spawn an async Task
        // to update the UI. The throttle drops calls that arrive within
        // `interval` of the previous emit — here the leading first line emits
        // and the trailing flush reports the final total, so a three-line burst
        // yields two callbacks (the middle line is dropped), not three.
        var progressCallCount = 0
        let scanner = makeScanner(
            installed: true,
            databaseDirectory: nil,
            excludedDirectories: [],
            progressThrottleInterval: 10.0  // only the leading line emits
        ) { _, _, onLine in
            onLine("/Users/x/a: OK")
            onLine("/Users/x/b: OK")
            onLine("/Users/x/c: OK")
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _, _ in progressCallCount += 1 }
        )

        XCTAssertEqual(progressCallCount, 2,
                       "the middle line is dropped by the throttle; the leading line and the terminal flush both emit")
    }

    /// The throttle limits how often progress is reported, but the reported
    /// files-checked count is tallied on every line at the source — so the one
    /// emitted callback in a throttled burst still carries the true total, not
    /// the number of emissions. Without this, a fast clean stretch undercounts.
    func test_scan_reportsTrueFileCountEvenWhenProgressIsThrottled() async throws {
        var lastReportedCount = 0
        var emissions = 0
        let scanner = makeScanner(
            installed: true,
            databaseDirectory: nil,
            excludedDirectories: [],
            progressThrottleInterval: 10.0  // only the first line emits
        ) { _, _, onLine in
            onLine("/Users/x/a: OK")
            onLine("/Users/x/b: OK")
            onLine("/Users/x/c: OK")
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _, filesScanned in
                emissions += 1
                lastReportedCount = filesScanned
            }
        )

        XCTAssertLessThan(emissions, 3, "the throttle must still drop mid-burst lines rather than emit per line")
        XCTAssertEqual(lastReportedCount, 3, "the terminal flush must report every line scanned, not the number of emissions")
    }

    func test_scan_parsesEveryThreatRegardlessOfProgressThrottle() async throws {
        // Throttling drops *progress* updates but every line is still
        // parsed for the `FOUND` suffix. A burst of infected files
        // arriving within the throttle window must all surface as
        // threats — otherwise we'd silently undercount detections.
        let scanner = makeScanner(
            installed: true,
            databaseDirectory: nil,
            excludedDirectories: [],
            progressThrottleInterval: 10.0
        ) { _, _, onLine in
            onLine("/Users/x/a: Eicar-A FOUND")
            onLine("/Users/x/b: Eicar-B FOUND")
            onLine("/Users/x/c: Eicar-C FOUND")
            return 1
        }

        let threats = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _, _ in }
        )

        XCTAssertEqual(threats.map(\.threatName), ["Eicar-A", "Eicar-B", "Eicar-C"])
    }

    func test_defaultExcludedDirectories_skipsObviousDevAndCacheNoise() {
        // Pinning the production default so the list can't silently
        // shift. These cover the trees that take the most time and
        // produce ~zero detection value: project-local noise (node
        // modules, .git), OS- and IDE-managed caches, Trash, and the
        // package-manager content stores that hold every version of
        // every dependency the user has ever installed.
        XCTAssertEqual(
            ClamAVScanner.defaultExcludedDirectories,
            [
                "/node_modules/",
                "/\\.git/",
                "/Library/Caches/",
                "/Library/Developer/",
                "/\\.Trash/",
                "/Library/Application Support/[^/]+/Cache/",
                "/Library/Application Support/[^/]+/Caches/",
                "/Library/Application Support/[^/]+/CachedData/",
                "/Library/pnpm/",
                "/\\.npm/",
                "/\\.yarn/",
                "/\\.cargo/registry/",
                "/\\.gradle/caches/",
                "/\\.m2/repository/"
            ]
        )
    }

    func test_deepScanAdditionalExcludedDirectories_skipsMediaAndCloudCaches() {
        // The Deep Scan stacks these on top of `defaultExcludedDirectories`
        // when walking the entire $HOME. They cover trees that are too
        // big to scan in reasonable time and contribute ~zero detection
        // value: photo and video libraries (binary media, not the file
        // formats ClamAV signatures match), iCloud Drive's local cache
        // (Apple already scans the canonical store on their side), and
        // Time Machine local snapshots (read-only, can't host malware
        // that isn't already in the source).
        XCTAssertEqual(
            ClamAVScanner.deepScanAdditionalExcludedDirectories,
            [
                "/Photos Library\\.photoslibrary/",
                "/Library/Mobile Documents/",
                "/\\.MobileBackups/",
                "/Library/MobileBackups/",
                "/Music/Music/Media\\.localized/",
                "/Music/iTunes/",
                "/Movies/"
            ]
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
        let scanner = makeScanner(
            installed: true,
            databaseDirectory: dbDirectory,
            excludedDirectories: []
        ) { _, arguments, _ in
            capturedArguments = arguments
            return 0
        }

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/x")],
            progress: { _, _ in }
        )

        XCTAssertEqual(
            capturedArguments,
            ["--database=\(dbDirectory.path)",
             "--recursive", "--no-summary",
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
            progress: { line, _ in progressLines.append(line) }
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
            progress: { _, _ in }
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
                progress: { _, _ in }
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
                progress: { _, _ in }
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
        excludedDirectories: [String]? = nil,
        progressThrottleInterval: TimeInterval = 0,
        runner: @escaping ClamAVScanner.ScanRunner
    ) -> ClamAVScanner {
        let detector = ClamAVDetector(
            candidatePaths: [binary],
            isExecutable: { _ in installed },
            versionRunner: { _ in nil }
        )
        // Default to no database directory and no exclusions so tests
        // run hermetically — the production defaults reach into the
        // user's home and Application Support, which would couple the
        // tests to the host filesystem. `progressThrottleInterval = 0`
        // means every line passes through, which most tests want.
        return ClamAVScanner(
            detector: detector,
            runner: runner,
            databaseDirectoryProvider: { databaseDirectory },
            excludedDirectories: excludedDirectories ?? [],
            progressThrottleInterval: progressThrottleInterval
        )
    }
}
