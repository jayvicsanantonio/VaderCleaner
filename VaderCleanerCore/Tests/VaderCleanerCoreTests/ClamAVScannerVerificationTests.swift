// ClamAVScannerVerificationTests.swift
// Pins that ClamAVScanner only surfaces threats a re-scan confirms, so a filename carrying a newline cannot forge a FOUND line for a file it doesn't own.

import CryptoKit
import Foundation
import Testing
@testable import VaderCleanerCore

/// clamscan prints each path verbatim, newlines included, so a planted file
/// named `thesis.docx: Win.Trojan.Fake-1 FOUND\ny` under a directory named
/// `x\n` (and a mirror of the victim's path) makes the output contain a
/// standalone, well-formed FOUND line for a clean file the attacker chose.
/// These suites drive the scanner with that exact output.
@Suite
struct ClamAVScannerVerificationTests {

    private static let binary = URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")

    @Test
    func forgedLineFromANewlineFilenameIsNotReported() async throws {
        // The three lines clamscan 1.5.3 prints for
        // `/Users/me/Downloads/x\n/Users/me/Documents/thesis.docx: Win.Trojan.Fake-1 FOUND\ny`,
        // a clean file — so clamscan itself exits 0.
        let clamscan = FakeClamscan(
            recursiveOutput: [
                "/Users/me/Downloads/x",
                "/Users/me/Documents/thesis.docx: Win.Trojan.Fake-1 FOUND",
                "y: OK"
            ],
            recursiveStatus: 0
        )
        let scanner = makeScanner(runner: clamscan.runner)

        let threats = try await scanner.scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(threats.isEmpty, "the victim is clean when scanned on its own, so the forged verdict must be dropped")
    }

    @Test
    func forgedLineNamingItsOwnDirectoryIsNotReported() async throws {
        // A single file named `: Win.Trojan.Fake-1 FOUND\nb` makes clamscan
        // print `<dir>/: Win.Trojan.Fake-1 FOUND`, which parses to the directory
        // itself — and removing that is recursive. Re-scanning the directory
        // lists the same file again, so a re-scan alone would "confirm" it.
        let downloads = "/Users/me/Downloads"
        let directoryListing = [
            "\(downloads)/: Win.Trojan.Fake-1 FOUND",
            "b: OK",
            "\(downloads)/report.pdf: OK"
        ]
        let clamscan = FakeClamscan(
            recursiveOutput: directoryListing,
            recursiveStatus: 0,
            explicitOutput: [downloads: directoryListing]
        )
        let scanner = makeScanner(
            runner: clamscan.runner,
            isRegularFile: { $0.path != downloads }
        )

        let threats = try await scanner.scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(threats.isEmpty, "clamscan only ever reports regular files, so a directory verdict is forged")
    }

    @Test(arguments: [
        "/Library/Application Support/Vendor/agent.dylib",
        "/Users/me/Downloads-old/sample.bin"
    ])
    func forgedLineOutsideTheScanRootsIsNotReported(outsidePath: String) async throws {
        // Even a file that really is infected stays out of the results when
        // the scan never covered it: the user didn't choose to scan it, and a
        // path under /Library would be removed through the root helper. The
        // second case is a sibling that shares the root's string prefix.
        let clamscan = FakeClamscan(
            recursiveOutput: [
                "/Users/me/Downloads/x",
                "\(outsidePath): Win.Trojan.Fake-1 FOUND",
                "y: OK"
            ],
            recursiveStatus: 0,
            explicitOutput: [outsidePath: ["\(outsidePath): Osx.Malware.Agent-1 FOUND"]]
        )
        let scanner = makeScanner(runner: clamscan.runner)

        let threats = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/me/Downloads")],
            progress: { _, _ in }
        )

        #expect(threats.isEmpty)
    }

    @Test
    func genuineThreatSurvivesVerification() async throws {
        let sample = "/Users/me/Downloads/sample.bin"
        let clamscan = FakeClamscan(
            recursiveOutput: ["\(sample): Eicar-Test-Signature FOUND"],
            recursiveStatus: 1,
            explicitOutput: [sample: ["\(sample): Eicar-Test-Signature FOUND"]]
        )
        let scanner = makeScanner(runner: clamscan.runner)

        let threats = try await scanner.scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(threats == [MalwareThreat(filePath: URL(fileURLWithPath: sample), threatName: "Eicar-Test-Signature")])
    }

    @Test
    func forgedDuplicateOfAGenuineThreatTakesTheRescannedVerdict() async throws {
        // An attacker who can't make a file clean can still forge a second,
        // scarier line for it. The re-scan's verdict is the one that counts,
        // and the file is reported once.
        let sample = "/Users/me/Downloads/sample.bin"
        let clamscan = FakeClamscan(
            recursiveOutput: [
                "\(sample): Eicar-Test-Signature FOUND",
                "/Users/me/Downloads/x",
                "\(sample): Osx.Ransomware.Fake-1 FOUND",
                "y: OK"
            ],
            recursiveStatus: 1,
            explicitOutput: [sample: ["\(sample): Eicar-Test-Signature FOUND"]]
        )
        let scanner = makeScanner(runner: clamscan.runner)

        let threats = try await scanner.scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(threats == [MalwareThreat(filePath: URL(fileURLWithPath: sample), threatName: "Eicar-Test-Signature")])
    }

    @Test
    func verificationRescansOnlyTheReportedFilesWithTheScanOptions() async throws {
        // The re-scan names each reported file explicitly, without
        // `--recursive`, and keeps the database and option flags of the full
        // scan — `--exclude` in particular, which clamscan applies to an
        // explicit file too, so an Ignore List file stays ignored.
        let sample = "/Users/me/Downloads/sample.bin"
        let clamscan = FakeClamscan(
            recursiveOutput: [
                "/Users/me/Downloads/report.pdf: OK",
                "\(sample): Eicar-Test-Signature FOUND"
            ],
            recursiveStatus: 1,
            explicitOutput: [sample: ["\(sample): Eicar-Test-Signature FOUND"]]
        )
        let scanner = makeScanner(
            runner: clamscan.runner,
            databaseDirectory: URL(fileURLWithPath: "/db"),
            excludedDirectories: ["/node_modules/"],
            excludedFiles: ["^/Users/me/Notes\\.txt$"]
        )

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/me")],
            options: ClamAVScanner.ScanOptions(scanMail: false, scanArchives: true),
            progress: { _, _ in }
        )

        #expect(clamscan.invocations.value == [
            ["--database=/db", "--exclude-dir=/node_modules/", "--exclude=^/Users/me/Notes\\.txt$",
             "--recursive", "--no-summary", "--scan-mail=no", "/Users/me"],
            ["--database=/db", "--exclude-dir=/node_modules/", "--exclude=^/Users/me/Notes\\.txt$",
             "--no-summary", "--scan-mail=no", sample]
        ])
    }

    @Test
    func cleanScanRunsNoVerification() async throws {
        let clamscan = FakeClamscan(recursiveOutput: ["/Users/me/Downloads/report.pdf: OK"], recursiveStatus: 0)
        let scanner = makeScanner(runner: clamscan.runner)

        _ = try await scanner.scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(clamscan.invocations.value.count == 1)
    }

    @Test
    func failedVerificationThrowsRatherThanDroppingThreats() async throws {
        // A re-scan that errors out (exit 2) proves nothing either way.
        // Treating its silence as "clean" would hide real malware, so the
        // scan fails the way a failed full scan does.
        let sample = "/Users/me/Downloads/sample.bin"
        let scanner = makeScanner(runner: { _, arguments, onLine in
            guard arguments.contains("--recursive") else { return 2 }
            onLine("\(sample): Eicar-Test-Signature FOUND")
            return 1
        })

        await #expect(throws: (any Error).self) {
            _ = try await scanner.scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })
        }
    }

    @Test
    func verificationOutputDoesNotReachProgress() async throws {
        // The files-checked count is the full scan's; the re-scan must not
        // inflate it or replay lines into the live log.
        let sample = "/Users/me/Downloads/sample.bin"
        let clamscan = FakeClamscan(
            recursiveOutput: ["/Users/me/Downloads/report.pdf: OK", "\(sample): Eicar-Test-Signature FOUND"],
            recursiveStatus: 1,
            explicitOutput: [sample: ["\(sample): Eicar-Test-Signature FOUND"]]
        )
        let scanner = makeScanner(runner: clamscan.runner)
        let reportedCounts = TestBox<[Int]>([])

        _ = try await scanner.scan(
            paths: [URL(fileURLWithPath: "/Users/me")],
            progress: { _, filesScanned in reportedCounts.withLock { $0.append(filesScanned) } }
        )

        #expect(reportedCounts.value == [1, 2])
    }

    // MARK: - Helpers

    private func makeScanner(
        runner: @escaping ClamAVScanner.ScanRunner,
        databaseDirectory: URL? = nil,
        excludedDirectories: [String] = [],
        excludedFiles: [String] = [],
        isRegularFile: @escaping ClamAVScanner.RegularFileProbe = { _ in true }
    ) -> ClamAVScanner {
        ClamAVScanner(
            detector: ClamAVDetector(
                candidatePaths: [Self.binary],
                isExecutable: { _ in true },
                versionRunner: { _ in nil }
            ),
            runner: runner,
            databaseDirectoryProvider: { databaseDirectory },
            excludedDirectories: excludedDirectories,
            excludedFiles: excludedFiles,
            progressThrottleInterval: 0,
            isRegularFile: isRegularFile
        )
    }
}

/// Stands in for `clamscan`. A recursive scan prints `recursiveOutput`
/// verbatim; a scan of explicit paths prints each path's entry in
/// `explicitOutput`, or `<path>: OK` for one it doesn't list — the way
/// clamscan reports each command-line argument.
private struct FakeClamscan: Sendable {

    var recursiveOutput: [String]
    var recursiveStatus: Int32
    var explicitOutput: [String: [String]] = [:]
    let invocations = TestBox<[[String]]>([])

    var runner: ClamAVScanner.ScanRunner {
        { _, arguments, onLine in
            invocations.withLock { $0.append(arguments) }
            if arguments.contains("--recursive") {
                recursiveOutput.forEach(onLine)
                return recursiveStatus
            }
            var found = false
            for path in arguments where !path.hasPrefix("--") {
                for line in explicitOutput[path] ?? ["\(path): OK"] {
                    found = found || line.hasSuffix(" FOUND")
                    onLine(line)
                }
            }
            return found ? 1 : 0
        }
    }
}

@Suite
struct ClamAVScannerRegularFileProbeTests {

    @Test
    func acceptsOnlyARegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClamAVScannerRegularFileProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.bin")
        try Data("sample".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let probe = ClamAVScanner.defaultRegularFileProbe

        #expect(probe(file))
        #expect(!probe(directory), "removing a directory is recursive")
        #expect(!probe(link), "clamscan never reports a symlink it meets while recursing")
        #expect(!probe(directory.appendingPathComponent("missing.bin")))
    }
}

/// Runs the real bundled `clamscan` over a real tree planted the way the
/// attack plants it. Needs `Vendor/clamav`, which `Scripts/bundle-clamav.sh`
/// populates and git ignores, so it only runs where that has been staged.
@Suite
struct ClamAVScannerForgedOutputIntegrationTests {

    private static let vendor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // VaderCleanerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // VaderCleanerCore
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("Vendor/clamav")
    private static let clamscan = vendor.appendingPathComponent("bin/clamscan")
    private static let certs = vendor.appendingPathComponent("certs")

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: clamscan.path)))
    func reportsOnlyTheGenuinelyInfectedFile() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("ClamAVScannerForgedOutput-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("home")
        let downloads = root.appendingPathComponent("Downloads")
        let documents = root.appendingPathComponent("Documents")
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        // A clean victim, and a forgery of it: `x\n` followed by a mirror of
        // the victim's directory, holding a file whose name ends the forged line.
        let victim = documents.appendingPathComponent("thesis.docx")
        try Data("clean".utf8).write(to: victim)
        let mirror = URL(fileURLWithPath: root.path + "/x\n" + documents.path)
        try fileManager.createDirectory(at: mirror, withIntermediateDirectories: true)
        try Data("clean".utf8).write(to: mirror.appendingPathComponent("thesis.docx: Win.Trojan.Fake-1 FOUND\ny"))

        // A forgery of the Downloads directory itself, beside a file the user keeps.
        try Data("clean".utf8).write(to: downloads.appendingPathComponent("report.pdf"))
        try Data("clean".utf8).write(to: downloads.appendingPathComponent(": Win.Trojan.Fake-1 FOUND\nb"))

        // One file the test database genuinely detects, by its MD5.
        let infected = downloads.appendingPathComponent("sample.bin")
        let payload = Data("VaderCleaner ClamAV verification fixture".utf8)
        try payload.write(to: infected)
        let database = workspace.appendingPathComponent("db")
        try fileManager.createDirectory(at: database, withIntermediateDirectories: true)
        let md5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try Data("\(md5):\(payload.count):VaderCleaner.Test.Fixture\n".utf8)
            .write(to: database.appendingPathComponent("test.hdb"))

        // The production runner finds the certs inside the app bundle, which a
        // hostless test doesn't have, so this one points clamscan at the
        // vendored copy the same way — through `CVD_CERTS_DIR`.
        let certs = Self.certs
        let scanner = ClamAVScanner(
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

        let threats = try await scanner.scan(paths: [root], progress: { _, _ in })

        #expect(threats.map(\.filePath.path) == [infected.path])
        #expect(threats.map(\.threatName) == ["VaderCleaner.Test.Fixture.UNOFFICIAL"])
    }
}
