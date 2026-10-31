// ClamAVScannerEngineSelfTestTests.swift
// Pins that a scan refuses to run when clamscan can't detect a known sample, so a broken engine can never pass for a clean Mac.

import Foundation
import Testing
@testable import VaderCleanerCore

/// A clamscan linked against OpenSSL 4.1 fails every hash, prints `<file>: OK`,
/// and exits 0, which is byte for byte what a clean scan looks like. Only asking
/// it to find something it must find tells the two apart.
@Suite
struct ClamAVScannerEngineSelfTestTests {

    private static let binary = URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")

    private func makeScanner(runner: @escaping ClamAVScanner.ScanRunner) -> ClamAVScanner {
        ClamAVScanner(
            detector: ClamAVDetector(
                candidatePaths: [Self.binary],
                isExecutable: { _ in true },
                versionRunner: { _ in nil }
            ),
            runner: runner,
            databaseDirectoryProvider: { URL(fileURLWithPath: "/Users/me/db") },
            excludedDirectories: ["/node_modules/"],
            progressThrottleInterval: 0
        )
    }

    private func scan(with runner: @escaping ClamAVScanner.ScanRunner) async throws -> [MalwareThreat] {
        try await makeScanner(runner: runner)
            .scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })
    }

    private func isSelfTest(_ arguments: [String]) -> Bool {
        !arguments.contains("--recursive")
    }

    /// What a working clamscan prints for the self-test: the sample, FOUND.
    private func healthyRunner(
        invocations: TestBox<[[String]]>,
        mainScanOutput: [String] = [],
        mainScanStatus: Int32 = 0
    ) -> ClamAVScanner.ScanRunner {
        { _, arguments, onLine in
            invocations.withLock { $0.append(arguments) }
            guard self.isSelfTest(arguments), let sample = arguments.last else {
                mainScanOutput.forEach(onLine)
                return mainScanStatus
            }
            onLine("\(sample): \(ClamAVScanner.selfTestSignatureName).UNOFFICIAL FOUND")
            return 1
        }
    }

    @Test
    func anEngineThatPassesTheSampleAsCleanFailsTheScan() async {
        let invocations = TestBox<[[String]]>([])
        await #expect(throws: ClamAVEngineError.selfTestFailed) {
            _ = try await scan { _, arguments, onLine in
                invocations.withLock { $0.append(arguments) }
                if let sample = arguments.last { onLine("\(sample): OK") }
                return 0
            }
        }
        let calls = invocations.withLock { $0 }
        #expect(calls.count == 1)
        #expect(!calls.contains { $0.contains("--recursive") }, "a broken engine must not walk the disk")
    }

    @Test
    func aHealthyEngineGoesOnToScan() async throws {
        let invocations = TestBox<[[String]]>([])
        let threats = try await scan(with: healthyRunner(invocations: invocations))
        #expect(threats.isEmpty)
        let calls = invocations.withLock { $0 }
        #expect(calls.count == 2)
        #expect(!calls[0].contains("--recursive"), "the self-test comes first")
        #expect(calls[1].contains("--recursive"))
    }

    @Test
    func theSelfTestUsesItsOwnDatabaseAndNoneOfTheScansSettings() async throws {
        let invocations = TestBox<[[String]]>([])
        _ = try await scan(with: healthyRunner(invocations: invocations))
        let arguments = invocations.withLock { $0[0] }
        #expect(!arguments.contains("--database=/Users/me/db"))
        #expect(!arguments.contains { $0.hasPrefix("--exclude") })
        #expect(arguments.contains("--no-summary"))
    }

    /// Only the sample being reported counts, under the signature it was given,
    /// from a run that says it found something.
    @Test(arguments: [
        (Int32(1), "/somewhere/else: VaderCleaner.Engine.SelfTest.UNOFFICIAL FOUND"),
        (Int32(1), "SAMPLE: Win.Trojan.Other-1 FOUND"),
        (Int32(0), "SAMPLE: VaderCleaner.Engine.SelfTest.UNOFFICIAL FOUND"),
        (Int32(2), "SAMPLE: VaderCleaner.Engine.SelfTest.UNOFFICIAL FOUND"),
    ])
    func anythingButTheExpectedVerdictFails(status: Int32, line: String) async {
        await #expect(throws: ClamAVEngineError.selfTestFailed) {
            _ = try await scan { _, arguments, onLine in
                onLine(line.replacingOccurrences(of: "SAMPLE", with: arguments.last ?? ""))
                return status
            }
        }
    }

    @Test
    func theDatabaseIsARealSignatureForTheSampleAndBothAreCleanedUp() async throws {
        let paths = TestBox<[String]>([])
        let signature = TestBox<String>("")
        let sampleSize = TestBox<Int>(0)
        _ = try await scan { _, arguments, onLine in
            guard self.isSelfTest(arguments), let sample = arguments.last else { return 0 }
            let database = arguments.first { $0.hasPrefix("--database=") }?
                .replacingOccurrences(of: "--database=", with: "") ?? ""
            paths.withLock { $0 = [sample, database] }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: database)) ?? []
            let contents = entries.first.flatMap { try? String(contentsOfFile: "\(database)/\($0)", encoding: .utf8) }
            signature.withLock { $0 = contents ?? "" }
            sampleSize.withLock { $0 = (try? Data(contentsOf: URL(fileURLWithPath: sample)).count) ?? -1 }
            onLine("\(sample): \(ClamAVScanner.selfTestSignatureName).UNOFFICIAL FOUND")
            return 1
        }
        let fields = signature.withLock { $0 }.trimmingCharacters(in: .newlines).split(separator: ":")
        #expect(fields.count == 3)
        #expect(fields.first?.count == 32, "an MD5 in hex")
        #expect(fields.dropFirst().first == "\(sampleSize.withLock { $0 })"[...])
        #expect(fields.last == ClamAVScanner.selfTestSignatureName[...])
        for path in paths.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: path), "\(path) should be gone")
        }
    }

    /// A planted file named to look like an engine failure is just a filename,
    /// and one unreadable file is just one file: neither can stop a scan.
    @Test
    func perFileErrorsAndForgedErrorLinesDoNotFailTheScan() async throws {
        let invocations = TestBox<[[String]]>([])
        let threats = try await scan(with: healthyRunner(
            invocations: invocations,
            mainScanOutput: [
                "/Users/me/Downloads/x",
                "LibClamAV Error: fmap_get_hash: error calculating sha2-256 hash!: OK",
                "/Users/me/secret.txt: Access denied",
                "/Users/me/locked: Can't open directory.",
            ]
        ))
        #expect(threats.isEmpty)
    }

    @Test
    func theFailureSaysNothingWasScanned() {
        let message = ClamAVEngineError.selfTestFailed.localizedDescription
        #expect(message.localizedCaseInsensitiveContains("nothing was scanned"))
    }
}
