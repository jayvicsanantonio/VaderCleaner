// DefaultBrewRunner.swift
// Production BrewRunning implementation — runs `brew` as a user-context child process with inherited environment and a closed stdin, buffering short queries and streaming long operations.

import Foundation

/// Runs the real `brew` executable. Homebrew refuses to run as root, so this is
/// deliberately a plain user-context `Process` and never routes through the
/// privileged XPC helper.
///
/// The child environment is derived from the app's own environment so `HOME`,
/// `PATH`, and locale survive, then hardened with `HOMEBREW_NO_AUTO_UPDATE`
/// (so only an explicit `brew update` hits the network) and
/// `HOMEBREW_NO_ENV_HINTS` (so hint text doesn't pollute parsed output). stdin
/// is closed on every invocation so an interactive `sudo` prompt fails fast
/// rather than hanging.
struct DefaultBrewRunner: BrewRunning {

    private let brewURL: URL

    init(brewURL: URL) {
        self.brewURL = brewURL
    }

    func runCapturing(_ arguments: [String]) async throws -> BrewResult {
        let brewURL = self.brewURL
        let environment = Self.childEnvironment()
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = brewURL
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()

            // Read both pipes concurrently: draining only one while the other
            // fills its buffer would deadlock a chatty command.
            async let outData = Self.readToEnd(outPipe.fileHandleForReading)
            async let errData = Self.readToEnd(errPipe.fileHandleForReading)
            let (out, err) = await (outData, errData)
            process.waitUntilExit()

            return BrewResult(
                terminationStatus: process.terminationStatus,
                standardOutput: String(decoding: out, as: UTF8.self),
                standardError: String(decoding: err, as: UTF8.self)
            )
        }.value
    }

    func runStreaming(_ arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await ProcessLineStreamer.run(
            executable: brewURL,
            arguments: arguments,
            environment: Self.childEnvironment(),
            mergeStandardError: true,
            closeStandardInput: true,
            onLine: onLine
        )
    }

    // MARK: - Private

    /// Derives the child environment from the app's own so `HOME`/`PATH`/locale
    /// survive, adding the two Homebrew flags that keep behavior predictable and
    /// output parseable.
    private static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        return environment
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .userInitiated) {
            // `readToEnd()` throws a catchable Swift error on I/O failure; the
            // older `readDataToEndOfFile()` raises an uncatchable NSException
            // that would crash the app if the pipe disconnects unexpectedly.
            (try? handle.readToEnd()) ?? Data()
        }.value
    }
}
