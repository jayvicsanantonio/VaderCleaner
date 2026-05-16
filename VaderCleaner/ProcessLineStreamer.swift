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
    static func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            try process.run()

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
    }

    private static func emit(_ data: Data, to onLine: (String) -> Void) {
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else { return }
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.isEmpty else { return }
        onLine(line)
    }
}
