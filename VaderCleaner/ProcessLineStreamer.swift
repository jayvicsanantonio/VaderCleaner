// ProcessLineStreamer.swift
// Runs a child process and delivers its stdout one complete line at a time, used by the ClamAV scan and database-update flows.

import Foundation

/// Runs an external command and streams its stdout line by line.
///
/// `freshclam` and `clamscan` emit progress continuously over a long run, so
/// the UI wants each line as it arrives rather than one blob at the end.
/// `availableData` hands back arbitrary byte chunks — a single read can split
/// a line or carry several — so output is buffered and only emitted on a
/// newline boundary, with the trailing partial line flushed at EOF so a final
/// `FOUND` verdict is never lost.
enum ProcessLineStreamer {

    private static let newline: UInt8 = 0x0A

    /// Launches `executable arguments`, invoking `onLine` for every complete
    /// stdout line (and the final unterminated one), and returns the process
    /// termination status. The blocking read loop runs off the caller's
    /// thread. stderr is routed to `/dev/null` so a chatty command can't
    /// deadlock on an unread pipe buffer.
    ///
    /// When `environment` is non-nil it replaces the child's environment
    /// wholesale — callers that want to add a variable should derive
    /// from `ProcessInfo.processInfo.environment` first so PATH / HOME /
    /// the user's locale aren't dropped on the floor.
    ///
    /// When `mergeStandardError` is true the child's stderr is routed into the
    /// same pipe as stdout, so its lines are delivered through `onLine` too.
    /// This is off by default — the ClamAV callers deliberately discard stderr —
    /// but `brew` writes progress and error text to stderr, so the Homebrew
    /// path needs it interleaved rather than dropped.
    ///
    /// When `closeStandardInput` is true the child's stdin is `/dev/null`, so a
    /// subprocess that tries to prompt interactively (e.g. a cask uninstaller
    /// invoking `sudo`) reads EOF and fails fast instead of blocking forever.
    ///
    /// Cancellation: if the calling Task is cancelled, the child process
    /// is SIGTERM-ed via `Process.terminate()`. clamscan exits within a
    /// second, the read loop sees EOF, and `run()` returns the (signal-
    /// derived) termination status to the caller. Without this the
    /// detached read loop would block on `waitUntilExit()` forever and
    /// the child would outlive its parent — a real concern in the
    /// Malware Removal flow where the user can cancel mid-scan or quit
    /// the app while clamscan is still walking the home directory.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        mergeStandardError: Bool = false,
        closeStandardInput: Bool = false,
        onLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if closeStandardInput {
            process.standardInput = FileHandle.nullDevice
        }
        let outputPipe = Pipe()
        if mergeStandardError {
            // `brew` writes progress and errors to stderr; route both streams to
            // the same write handle so their lines are streamed rather than
            // lost. Passing the FileHandle (not the Pipe) to both means
            // Foundation does not auto-close it — assigning one Pipe to both
            // standardOutput and standardError leaves the write end open in the
            // parent, so the reader never sees EOF and `availableData` blocks
            // forever. We close the parent's copy ourselves after launch below.
            let writeHandle = outputPipe.fileHandleForWriting
            process.standardOutput = writeHandle
            process.standardError = writeHandle
        } else {
            process.standardOutput = outputPipe
            // Other callers (ClamAV) deliberately discard stderr.
            process.standardError = FileHandle.nullDevice
        }

        // Launch synchronously before the cancellation handler is wired
        // up so a fast cancellation can't see `process.isRunning == false`
        // and skip the terminate() — the handler only fires after this
        // line returns, and by then we're committed.
        try process.run()

        if mergeStandardError {
            // The child inherited its own dup of the write end at spawn; close
            // the parent's copy now so the reader gets EOF when the child exits.
            try? outputPipe.fileHandleForWriting.close()
        }

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let handle = outputPipe.fileHandleForReading
                var buffer = Data()
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    buffer.append(chunk)
                    while let newlineIndex = buffer.firstIndex(of: newline) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                        buffer.removeSubrange(buffer.startIndex...newlineIndex)
                        emit(lineData, to: onLine)
                    }
                }
                // EOF — the process closed stdout without a final newline.
                emit(buffer, to: onLine)

                process.waitUntilExit()
                return process.terminationStatus
            }.value
        } onCancel: {
            // `terminate()` is documented as safe to call from any
            // thread. It sends SIGTERM; the read loop unblocks on EOF
            // and the function returns through its normal path.
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func emit(_ data: Data, to onLine: (String) -> Void) {
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else { return }
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.isEmpty else { return }
        onLine(line)
    }
}
