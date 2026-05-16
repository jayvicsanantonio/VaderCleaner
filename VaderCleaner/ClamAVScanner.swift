// ClamAVScanner.swift
// Runs clamscan over the requested paths, streams progress line by line, and returns the parsed list of detected threats.

import Foundation
import os.log

/// Scans paths for malware with `clamscan` and returns the matches.
///
/// The binary location comes from a `ClamAVDetector`; the actual process
/// run is delegated to an injected `ScanRunner` so argument construction
/// and exit-code handling are unit-testable without a real ClamAV. Output
/// is both forwarded to the caller's `progress` closure (for a live log)
/// and accumulated for parsing once the scan completes.
struct ClamAVScanner {

    /// Runs `executable arguments`, invoking `onLine` per stdout line, and
    /// returns the process exit code.
    typealias ScanRunner = (
        _ executable: URL,
        _ arguments: [String],
        _ onLine: @escaping (String) -> Void
    ) async throws -> Int32

    private let detector: ClamAVDetector
    private let runner: ScanRunner
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "ClamAVScanner")

    init(
        detector: ClamAVDetector = ClamAVDetector(),
        runner: @escaping ScanRunner = ClamAVScanner.defaultRunner
    ) {
        self.detector = detector
        self.runner = runner
    }

    /// Scans `paths` recursively, reporting infected files only. `progress`
    /// receives each `clamscan` output line as it streams.
    ///
    /// `clamscan` exits 0 when nothing is found and 1 when at least one
    /// infection is found — both are *successful* scans. Only exit code 2
    /// (a hard error) or an unreachable binary throws.
    func scan(
        paths: [URL],
        progress: @escaping (String) -> Void
    ) async throws -> [MalwareThreat] {
        guard let binary = detector.path() else {
            throw NSError(
                domain: "com.personal.VaderCleaner.ClamAVScanner",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ClamAV is not installed"]
            )
        }

        let arguments = ["--recursive", "--infected", "--no-summary"]
            + paths.map(\.path)

        let collector = LineCollector()
        let status = try await runner(binary, arguments) { line in
            collector.append(line)
            progress(line)
        }

        // 0 = clean, 1 = virus(es) found, 2 = error. Anything else (or a
        // negative signal status) is a failure we surface rather than
        // silently report "no threats".
        guard status == 0 || status == 1 else {
            log.error("clamscan exited with status \(status, privacy: .public)")
            throw NSError(
                domain: "com.personal.VaderCleaner.ClamAVScanner",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "clamscan exited with status \(status)"]
            )
        }

        return ClamAVOutputParser.parse(collector.joined())
    }

    // MARK: - Production collaborator

    static let defaultRunner: ScanRunner = { executable, arguments, onLine in
        try await ProcessLineStreamer.run(
            executable: executable,
            arguments: arguments,
            onLine: onLine
        )
    }
}

/// Thread-safe accumulator for the scan's stdout lines. `ProcessLineStreamer`
/// invokes the line callback from its background read loop, so the buffer is
/// guarded the same way as `SystemJunkDeleter`'s once-only resumer.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return snapshot.joined(separator: "\n")
    }
}
