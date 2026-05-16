// ProcessLineStreamerTests.swift
// Exercises ProcessLineStreamer end-to-end via /bin/sh: newline splitting, trailing-partial flush at EOF, exit-code propagation, and empty output.

import XCTest
@testable import VaderCleaner

final class ProcessLineStreamerTests: XCTestCase {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    func test_run_splitsNewlineTerminatedOutputIntoLines() async throws {
        let collector = Collector()
        let status = try await ProcessLineStreamer.run(
            executable: sh,
            arguments: ["-c", "printf 'a\\nb\\nc\\n'"],
            onLine: collector.append
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(collector.snapshot(), ["a", "b", "c"])
    }

    func test_run_flushesTrailingPartialLineWithoutFinalNewline() async throws {
        // The final "y" has no terminating newline — it must still be
        // delivered (a final "… FOUND" verdict can land here).
        let collector = Collector()
        let status = try await ProcessLineStreamer.run(
            executable: sh,
            arguments: ["-c", "printf 'x\\ny'"],
            onLine: collector.append
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(collector.snapshot(), ["x", "y"])
    }

    func test_run_propagatesNonZeroExitStatus() async throws {
        let collector = Collector()
        let status = try await ProcessLineStreamer.run(
            executable: sh,
            arguments: ["-c", "exit 2"],
            onLine: collector.append
        )
        XCTAssertEqual(status, 2)
        XCTAssertTrue(collector.snapshot().isEmpty)
    }

    func test_run_handlesEmptyOutput() async throws {
        let collector = Collector()
        let status = try await ProcessLineStreamer.run(
            executable: sh,
            arguments: ["-c", "true"],
            onLine: collector.append
        )
        XCTAssertEqual(status, 0)
        XCTAssertTrue(collector.snapshot().isEmpty)
    }

    /// `onLine` is invoked from the streamer's background read loop, so the
    /// collected lines are guarded the same way production callers guard
    /// their accumulators.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }
}
