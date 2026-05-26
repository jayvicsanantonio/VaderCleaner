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

    /// Resolves the signature-database directory clamscan should read
    /// from. Returns `nil` to fall back to clamscan's compiled-in
    /// default — useful for tests and for a developer using a Homebrew
    /// `clamscan` with its own DB layout.
    typealias DatabaseDirectoryProvider = () -> URL?

    /// Directory-path regexes (clamscan's `--exclude-dir` flavour) that
    /// the scanner should skip. Walking these on a developer machine
    /// dominates scan time while contributing ~zero detection value:
    /// content-addressed package stores hold third-party code we'd
    /// re-fetch from the same registries on every machine, and OS- or
    /// IDE-managed caches are regenerable. Pinned by
    /// `test_defaultExcludedDirectories_skipsObviousDevAndCacheNoise`.
    static let defaultExcludedDirectories: [String] = [
        // Per-project noise
        "/node_modules/",
        "/\\.git/",

        // System-level caches and dev-tool homes
        "/Library/Caches/",
        "/Library/Developer/",   // Xcode DerivedData / iOS device support
        "/\\.Trash/",

        // Electron / IDE app caches that live under Application Support
        // rather than Library/Caches (VSCode, Windsurf, Slack, Discord…)
        "/Library/Application Support/[^/]+/Cache/",
        "/Library/Application Support/[^/]+/Caches/",
        "/Library/Application Support/[^/]+/CachedData/",

        // Package-manager content stores — every version of every dep
        // the user has ever installed, deduped. Usually multi-GB.
        "/Library/pnpm/",
        "/\\.npm/",
        "/\\.yarn/",
        "/\\.cargo/registry/",
        "/\\.gradle/caches/",
        "/\\.m2/repository/"
    ]

    private let detector: ClamAVDetector
    private let runner: ScanRunner
    private let databaseDirectoryProvider: DatabaseDirectoryProvider
    private let excludedDirectories: [String]
    private let progressThrottleInterval: TimeInterval
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "ClamAVScanner")

    init(
        detector: ClamAVDetector = ClamAVDetector(),
        runner: @escaping ScanRunner = ClamAVScanner.defaultRunner,
        databaseDirectoryProvider: @escaping DatabaseDirectoryProvider =
            ClamAVScanner.defaultDatabaseDirectoryProvider,
        excludedDirectories: [String] = ClamAVScanner.defaultExcludedDirectories,
        progressThrottleInterval: TimeInterval = 0.1
    ) {
        self.detector = detector
        self.runner = runner
        self.databaseDirectoryProvider = databaseDirectoryProvider
        self.excludedDirectories = excludedDirectories
        self.progressThrottleInterval = progressThrottleInterval
    }

    /// Production default: the writable DB directory the bundled
    /// `freshclam` populates under Application Support. Returns `nil`
    /// when the runtime tree can't be created so clamscan falls back to
    /// its compiled-in default rather than failing the scan outright.
    static let defaultDatabaseDirectoryProvider: DatabaseDirectoryProvider = {
        try? BundledClamAVRuntime().databaseDirectory()
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

        // `--database` must point at the directory our bundled freshclam
        // populates; the bundled clamscan's compiled-in default is the
        // Homebrew Cellar path, which won't exist on a user machine.
        var arguments: [String] = []
        if let database = databaseDirectoryProvider() {
            arguments.append("--database=\(database.path)")
        }
        // `--exclude-dir` accepts a Perl-compatible regex per flag —
        // pass each pattern separately so clamscan combines them with
        // OR semantics. Listed before the scan targets so the override
        // is unambiguous.
        for pattern in excludedDirectories {
            arguments.append("--exclude-dir=\(pattern)")
        }
        // `--infected` (a.k.a. `-i`) suppresses the `: OK` lines that
        // make up >99% of clamscan's output on a clean machine — we
        // *want* those lines so the UI has a steady progress signal.
        // `ClamAVOutputParser.parseLine` already filters down to the
        // ` FOUND` suffix, so non-infection lines never become threats.
        arguments.append(contentsOf: ["--recursive", "--no-summary"])
        arguments.append(contentsOf: paths.map(\.path))

        let collector = ThreatCollector()
        let throttle = ProgressThrottle(interval: progressThrottleInterval)
        let status = try await runner(binary, arguments) { line in
            // Every line is parsed for threats so the throttle below
            // can't silently lose detections inside a tight burst of
            // infected files.
            if let threat = ClamAVOutputParser.parseLine(line) {
                collector.append(threat)
            }
            // The progress callback hops to the main actor in
            // `MalwareViewModel` and feeds an @Published phase; without
            // the throttle, a fast clean stretch would spam millions
            // of Tasks per scan.
            if throttle.shouldEmit() {
                progress(line)
            }
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

        return collector.snapshot()
    }

    // MARK: - Production collaborator

    static let defaultRunner: ScanRunner = { executable, arguments, onLine in
        // `clamscan` loads each `.cvd` through libclamav, which verifies
        // the file's detached signature against the cert pointed at by
        // `CVD_CERTS_DIR`. Without it, the bundled clamscan falls back
        // to its compiled-in Homebrew Cellar path and silently refuses
        // to load any database — every scan would then come back as
        // "no signatures loaded".
        var environment: [String: String]? = nil
        if let certs = BundledClamAVRuntime().bundledCVDCertsDirectory() {
            var env = ProcessInfo.processInfo.environment
            env["CVD_CERTS_DIR"] = certs.path
            environment = env
        }
        return try await ProcessLineStreamer.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            onLine: onLine
        )
    }
}

/// Rate-limits the scanner's progress callback to one call per
/// `interval` seconds. `ProcessLineStreamer` invokes the runner closure
/// from a single background read loop, so the timestamp doesn't need a
/// lock — but we mark `@unchecked Sendable` so the throttle can be
/// captured by the closure under Swift 6's strict concurrency rules.
///
/// An `interval` of `0` disables throttling entirely (every call emits)
/// — useful for tests asserting line-by-line behaviour without timing
/// games.
private final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private var lastEmit: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldEmit() -> Bool {
        guard interval > 0 else { return true }
        let now = Date()
        if let last = lastEmit, now.timeIntervalSince(last) < interval {
            return false
        }
        lastEmit = now
        return true
    }
}

/// Thread-safe accumulator for threats parsed as the scan streams.
/// `ProcessLineStreamer` invokes the line callback from its background read
/// loop, so the buffer is guarded the same way as `SystemJunkDeleter`'s
/// once-only resumer.
private final class ThreatCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var threats: [MalwareThreat] = []

    func append(_ threat: MalwareThreat) {
        lock.lock()
        threats.append(threat)
        lock.unlock()
    }

    func snapshot() -> [MalwareThreat] {
        lock.lock()
        defer { lock.unlock() }
        return threats
    }
}
