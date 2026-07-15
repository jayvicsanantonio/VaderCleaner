// BrewTestDoubles.swift
// Stub BrewLocating and BrewRunning used to drive HomebrewViewModel through every phase without a real Homebrew install.

import Foundation
@testable import VaderCleaner

/// Locator stub returning a fixed URL (or nil to simulate "not installed").
struct StubBrewLocator: BrewLocating {
    let url: URL?
    func locate() -> URL? { url }
}

/// Records every brew invocation and returns canned responses keyed by the
/// argument list (joined) or the first argument, so tests can assert exactly
/// what was run and feed fixture output back.
final class StubBrewRunner: BrewRunning, @unchecked Sendable {

    struct StreamResponse {
        var lines: [String] = []
        var status: Int32 = 0
    }

    /// Canned capture responses. Looked up by the full joined argument list
    /// first, then by the first argument.
    var captures: [String: BrewResult] = [:]
    /// Argument keys (joined or first) whose `runCapturing` should throw,
    /// simulating a brew that fails to run.
    var throwingCaptures: Set<String> = []
    /// Canned stream responses, same keying as `captures`.
    var streams: [String: StreamResponse] = [:]
    /// First-argument keys whose `runStreaming` hangs (honoring cancellation),
    /// used to exercise the stall watchdog.
    var hangingStreams: Set<String> = []
    /// First-argument (or joined) keys whose `runStreaming` throws a
    /// non-cancellation error, simulating a process launch/I/O failure.
    var throwingStreams: Set<String> = []

    private let lock = NSLock()
    private var _capturingCalls: [[String]] = []
    private var _streamingCalls: [[String]] = []

    var capturingCalls: [[String]] { lock.lock(); defer { lock.unlock() }; return _capturingCalls }
    var streamingCalls: [[String]] { lock.lock(); defer { lock.unlock() }; return _streamingCalls }

    func runCapturing(_ arguments: [String]) async throws -> BrewResult {
        lock.lock(); _capturingCalls.append(arguments); lock.unlock()
        let joined = arguments.joined(separator: " ")
        let first = arguments.first ?? ""
        if throwingCaptures.contains(joined) || throwingCaptures.contains(first) {
            throw StubError.failed
        }
        return captures[joined] ?? captures[first] ?? BrewResult(terminationStatus: 0, standardOutput: "", standardError: "")
    }

    func runStreaming(_ arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        lock.lock(); _streamingCalls.append(arguments); lock.unlock()
        let joined = arguments.joined(separator: " ")
        let first = arguments.first ?? ""
        if throwingStreams.contains(first) || throwingStreams.contains(joined) {
            throw StubError.failed
        }
        if hangingStreams.contains(first) || hangingStreams.contains(joined) {
            // Sleep long enough that only cancellation ends it.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return 0
        }
        let response = streams[joined] ?? streams[first] ?? StreamResponse()
        for line in response.lines { onLine(line) }
        return response.status
    }

    enum StubError: Error { case failed }
}
