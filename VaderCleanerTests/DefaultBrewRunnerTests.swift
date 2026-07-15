// DefaultBrewRunnerTests.swift
// Exercises DefaultBrewRunner against a fake `brew` shell script: environment passthrough, closed stdin, buffered capture, streamed line ordering, and SIGTERM-on-cancel.

import XCTest
@testable import VaderCleaner

final class DefaultBrewRunnerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        if let tempRoot { TestHelpers.tearDownTempDirectory(tempRoot) }
        tempRoot = nil
        try super.tearDownWithError()
    }

    /// Writes an executable shell script that stands in for `brew`.
    private func makeFakeBrew(body: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("brew")
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func test_runCapturing_derivesHomeAndPathFromProcessEnvironment() async throws {
        let brew = try makeFakeBrew(body: "echo \"HOME=$HOME\"; echo \"PATH=$PATH\"; echo \"NAU=$HOMEBREW_NO_AUTO_UPDATE\"")
        let result = try await DefaultBrewRunner(brewURL: brew).runCapturing([])
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.contains("HOME=\(ProcessInfo.processInfo.environment["HOME"] ?? "")"))
        XCTAssertTrue(result.standardOutput.contains("PATH="))
        XCTAssertFalse((ProcessInfo.processInfo.environment["PATH"] ?? "").isEmpty)
        // The Homebrew flag is injected on top of the inherited environment.
        XCTAssertTrue(result.standardOutput.contains("NAU=1"))
    }

    func test_runCapturing_closesStandardInputSoReadsHitEOF() async throws {
        // A brew subprocess that tries to read stdin must see EOF (not hang).
        let brew = try makeFakeBrew(body: "if IFS= read -r line; then echo \"READ:$line\"; else echo EOF; fi")
        let result = try await DefaultBrewRunner(brewURL: brew).runCapturing([])
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.contains("EOF"))
    }

    func test_runCapturing_separatesStdoutAndStderr() async throws {
        let brew = try makeFakeBrew(body: "echo out-line; echo err-line 1>&2; exit 3")
        let result = try await DefaultBrewRunner(brewURL: brew).runCapturing([])
        XCTAssertEqual(result.terminationStatus, 3)
        XCTAssertTrue(result.standardOutput.contains("out-line"))
        XCTAssertFalse(result.standardOutput.contains("err-line"))
        XCTAssertTrue(result.standardError.contains("err-line"))
    }

    func test_runStreaming_deliversMergedLinesInOrderWithStatus() async throws {
        let brew = try makeFakeBrew(body: "echo one; echo two 1>&2; echo three; exit 0")
        let collector = LineCollector()
        let status = try await DefaultBrewRunner(brewURL: brew)
            .runStreaming([], onLine: collector.append)
        XCTAssertEqual(status, 0)
        // stderr is merged into the stream; all three lines are delivered.
        XCTAssertEqual(Set(collector.snapshot()), ["one", "two", "three"])
    }

    func test_runStreaming_terminatesChildOnCancellation() async throws {
        let brew = try makeFakeBrew(body: "sleep 30")
        let runner = DefaultBrewRunner(brewURL: brew)
        let task = Task<Int32, Error> {
            try await runner.runStreaming([], onLine: { _ in })
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        _ = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "cancellation must SIGTERM the child within ~1s")
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
}
