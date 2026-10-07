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
        let process = Process()
        process.executableURL = brewURL
        process.arguments = arguments
        process.environment = Self.childEnvironment()
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Launched before the cancellation handler is wired up so a fast
        // cancellation can't see `isRunning == false` and skip the
        // terminate() — same ordering as `ProcessLineStreamer.run`.
        try process.run()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Both pipes are drained concurrently: waiting on one while
                // the other fills its 64 KB buffer deadlocks a chatty
                // command. `DispatchGroup.notify` rather than a blocking
                // join, so no thread on `blockingQueue` ever waits on
                // another block submitted to the same queue — that pattern
                // stalls once the queue's threads are all occupied by
                // waiters.
                let group = DispatchGroup()
                let out = DataBox()
                let err = DataBox()
                Self.blockingQueue.async(group: group) {
                    out.value = Self.readToEnd(outPipe.fileHandleForReading)
                }
                Self.blockingQueue.async(group: group) {
                    err.value = Self.readToEnd(errPipe.fileHandleForReading)
                }
                group.notify(queue: Self.blockingQueue) {
                    // Both pipes are at EOF by now, so the child has closed
                    // its descriptors and this returns promptly.
                    process.waitUntilExit()
                    continuation.resume(returning: BrewResult(
                        terminationStatus: process.terminationStatus,
                        standardOutput: String(decoding: out.value, as: UTF8.self),
                        standardError: String(decoding: err.value, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            // Without this a cancelled `brew` query leaves the child running
            // and this call blocked on `waitUntilExit()` for as long as it
            // takes. `terminate()` is documented safe from any thread; the
            // reads then hit EOF and the normal path returns.
            if process.isRunning {
                process.terminate()
            }
        }
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

    /// Dedicated queue for the blocking process I/O below.
    ///
    /// `Task.detached` runs on the cooperative pool, which is sized to the
    /// core count — and `waitUntilExit()` plus two `readToEnd()` calls block
    /// their threads outright rather than suspending. Three blocked pool
    /// threads per concurrent `brew` query is a forward-progress hazard on a
    /// machine with few cores, and `CareScanEngine` runs five lanes at once.
    /// A `.concurrent` `DispatchQueue` grows its own threads instead, so
    /// blocking here starves nothing.
    private static let blockingQueue = DispatchQueue(
        label: "com.personal.VaderCleaner.brew-runner",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Drains a pipe to EOF.
    ///
    /// `readToEnd()` throws a catchable Swift error on I/O failure; the older
    /// `readDataToEndOfFile()` raises an uncatchable NSException that would
    /// crash the app if the pipe disconnects unexpectedly.
    private static func readToEnd(_ handle: FileHandle) -> Data {
        (try? handle.readToEnd()) ?? Data()
    }

    /// Carries one pipe's bytes from its reader block to the `notify` block.
    ///
    /// `@unchecked Sendable`: the enclosing `DispatchGroup` orders the single
    /// write (inside the group) against the single read (in `notify`, which
    /// runs only after every group block has finished), so the two never
    /// overlap and no lock is needed.
    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }
}
