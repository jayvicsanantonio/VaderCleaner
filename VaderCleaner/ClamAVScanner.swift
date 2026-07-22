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

    /// Which content types clamscan inspects. Both default to `true` to match
    /// clamscan's own defaults, so a default-constructed value adds no flags —
    /// the scanner only emits an explicit `--scan-mail=no` / `--scan-archive=no`
    /// when the user has turned an option off in Protection settings.
    struct ScanOptions {
        var scanMail = true
        var scanArchives = true
    }

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

    /// Extra exclusions stacked on top of `defaultExcludedDirectories`
    /// only by a Balanced Scan, which walks the entire `$HOME`. These
    /// trees are irrelevant at Quick Scan scope (they aren't in
    /// Downloads/Desktop/Documents anyway) but dominate scan time on a
    /// whole-home pass — skipping them is exactly what separates Balanced
    /// from Deep, which keeps them in scope. Pinned by
    /// `test_mediaAndCloudExcludedDirectories_skipsBulkMediaAndCloudMirrors`.
    static let mediaAndCloudExcludedDirectories: [String] = [
        // Photos libraries are routinely 50–500 GB of binary image and
        // video data. Image-parser CVEs aren't what ClamAV signatures
        // catch — that's an XProtect / kernel concern.
        "/Photos Library\\.photoslibrary/",
        // iCloud Drive's local materialised copy; Apple already scans
        // the canonical store on their side.
        "/Library/Mobile Documents/",
        // Time Machine local snapshots — read-only, can't host malware
        // that wouldn't already be in the source.
        "/\\.MobileBackups/",
        "/Library/MobileBackups/",
        // Apple's media libraries — Music, TV, Podcasts. Multi-GB
        // streams or downloads of signed media files.
        "/Music/Music/Media\\.localized/",
        "/Music/iTunes/",
        // User-managed video dumps — typically the largest single
        // directory on a home Mac.
        "/Movies/"
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
    /// receives a streamed `clamscan` output line together with the running
    /// count of files checked so far — `clamscan` prints one line per file, so
    /// the count is the true files-checked total. The line is throttled (see
    /// `progressThrottleInterval`), but the count is tallied on *every* line at
    /// the source, so a fast clean stretch reports the real total rather than
    /// the number of throttled updates.
    ///
    /// `clamscan` exits 0 when nothing is found and 1 when at least one
    /// infection is found — both are *successful* scans. Only exit code 2
    /// (a hard error) or an unreachable binary throws.
    func scan(
        paths: [URL],
        options: ScanOptions = ScanOptions(),
        progress: @escaping (_ line: String, _ filesScanned: Int) -> Void
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
        // clamscan inspects mail and archives by default, so only emit the
        // disabling flags when the user has turned an option off — keeping the
        // default argument list (and its tests) unchanged.
        if !options.scanMail {
            arguments.append("--scan-mail=no")
        }
        if !options.scanArchives {
            arguments.append("--scan-archive=no")
        }
        arguments.append(contentsOf: paths.map(\.path))

        let collector = ThreatCollector()
        let throttle = ProgressThrottle(interval: progressThrottleInterval)
        let counter = LineCounter()
        let status = try await runner(binary, arguments) { line in
            // Every line is parsed for threats so the throttle below
            // can't silently lose detections inside a tight burst of
            // infected files.
            if let threat = ClamAVOutputParser.parseLine(line) {
                collector.append(threat)
            }
            // Count every line (one file each) at the source, so the reported
            // total is truthful even across a fast stretch. The throttle only
            // limits how often we *report* that total — the progress callback
            // hops to the main actor in `MalwareViewModel` and feeds an
            // @Published phase, so without the throttle a fast clean stretch
            // would spam millions of Tasks per scan.
            let scanned = counter.record(line)
            if throttle.shouldEmit() {
                counter.markReported()
                progress(line, scanned)
            }
        }

        // Flush the exact terminal total when the tail of the stream fell inside
        // a throttle window and was never reported — otherwise leading-edge
        // throttling would leave the readout short of the true files-checked
        // count at scan end. Skipped when the last line already emitted, so a
        // reported line is never sent twice. Safe to read the counter here: the
        // runner has returned, so its background read loop is done mutating it.
        if counter.hasUnreportedLines, let lastLine = counter.lastLine {
            progress(lastLine, counter.count)
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

/// Counts the lines the scan streams — one per file `clamscan` checks — so the
/// reported files-checked total is truthful regardless of how the progress
/// callback is throttled, and remembers the last line so the scan can flush the
/// exact terminal total once the stream ends. Like `ProgressThrottle`, it relies
/// on `ProcessLineStreamer`'s single background read loop for serialization and
/// is marked `@unchecked Sendable` only so the runner closure can capture it.
private final class LineCounter: @unchecked Sendable {
    private(set) var count = 0
    private(set) var lastLine: String?
    private var reportedCount = 0

    /// Records a streamed line and returns the new running total.
    func record(_ line: String) -> Int {
        count += 1
        lastLine = line
        return count
    }

    /// Marks the current total as reported through the progress callback.
    func markReported() {
        reportedCount = count
    }

    /// Whether lines have been counted since the last reported total — i.e. the
    /// tail of the stream fell inside a throttle window and needs a flush.
    var hasUnreportedLines: Bool {
        count > reportedCount
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
