// DatabaseUpdater.swift
// Reports the ClamAV signature database's last-update time and refreshes it by running freshclam.

import Foundation
import os

/// Tracks and refreshes the ClamAV signature database.
///
/// Checks for a bundled ClamAV first (staged by the build script), then
/// falls back to Homebrew which keeps signatures under `<prefix>/var/lib/clamav`
/// as `.cvd` (compressed, full) or `.cld` (incremental) files; their
/// modification time is the most reliable "last updated" signal without
/// parsing `freshclam.log`. Refreshing runs the `freshclam` tool. Database
/// directories, the `freshclam` location, the executable check, and the
/// runner are injected so both queries and updates are unit-testable
/// without a real ClamAV install.
struct DatabaseUpdater: Sendable {

    typealias ExecutableCheck = @Sendable (String) -> Bool
    typealias FreshclamRunner = @Sendable (
        _ executable: URL,
        _ onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32

    /// The two on-disk forms of a ClamAV signature database. `freshclam`
    /// keeps `main`, `daily`, and `bytecode` plus optional extras
    /// (`safebrowsing`, third-party feeds), so the directory is scanned by
    /// extension rather than against a fixed filename list — a hardcoded
    /// list would miss extra databases and report a stale last-update time.
    private static let signatureExtensions: Set<String> = ["cvd", "cld"]

    /// A signature database older than this is refreshed before a scan, so a
    /// stale install doesn't miss recent threats. Owned here rather than by a
    /// caller because both scan surfaces — the standalone Protection scan and
    /// Smart Scan's malware lane — have to agree on it; two copies of a
    /// security policy is exactly the drift this codebase avoids elsewhere.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private static let log = Logger(subsystem: "com.personal.VaderCleaner",
                                    category: "DatabaseUpdater")

    private let databaseDirectories: [URL]
    private let freshclamPaths: [URL]
    /// See `DefaultAppDiscovery.fileManager` — `.default` is documented
    /// thread-safe and test fixtures are single-threaded.
    nonisolated(unsafe) private let fileManager: FileManager
    private let isExecutable: ExecutableCheck
    private let runner: FreshclamRunner

    init(
        databaseDirectories: [URL] = DatabaseUpdater.defaultDatabaseDirectories(),
        freshclamPaths: [URL] = DatabaseUpdater.defaultFreshclamPaths(),
        fileManager: FileManager = .default,
        isExecutable: @escaping ExecutableCheck = { FileManager.default.isExecutableFile(atPath: $0) },
        runner: @escaping FreshclamRunner = DatabaseUpdater.defaultRunner
    ) {
        self.databaseDirectories = databaseDirectories
        self.freshclamPaths = freshclamPaths
        self.fileManager = fileManager
        self.isExecutable = isExecutable
        self.runner = runner
    }

    // MARK: - Default Paths

    /// Returns candidate database directories. The first entry is the
    /// writable runtime directory the bundled `freshclam` populates
    /// (`~/Library/Application Support/VaderCleaner/clamav/db/`); the
    /// Homebrew prefixes are kept as fallbacks for dev builds that opt
    /// out of the bundled binary.
    static func defaultDatabaseDirectories() -> [URL] {
        var paths: [URL] = []

        // 1. Bundled runtime — freshclam writes here, clamscan reads here.
        if let bundled = try? BundledClamAVRuntime().databaseDirectory() {
            paths.append(bundled)
        }

        // 2. Homebrew on Apple silicon
        paths.append(URL(fileURLWithPath: "/opt/homebrew/var/lib/clamav", isDirectory: true))

        // 3. Homebrew on Intel
        paths.append(URL(fileURLWithPath: "/usr/local/var/lib/clamav", isDirectory: true))

        return paths
    }

    /// Returns candidate `freshclam` paths, checking the bundled ClamAV
    /// first, then falling back to Homebrew prefixes.
    static func defaultFreshclamPaths() -> [URL] {
        var paths: [URL] = []

        // 1. Bundled ClamAV (staged by Scripts/stage-clamav.sh)
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("clamav/bin/freshclam", isDirectory: false) {
            paths.append(bundled)
        }

        // 2. Homebrew on Apple silicon
        paths.append(URL(fileURLWithPath: "/opt/homebrew/bin/freshclam"))

        // 3. Homebrew on Intel
        paths.append(URL(fileURLWithPath: "/usr/local/bin/freshclam"))

        return paths
    }

    /// The newest modification date across every signature file in every
    /// configured database directory, or `nil` when none are present
    /// (ClamAV not installed, or `freshclam` never run).
    func lastUpdateDate() -> Date? {
        newestSignatureDate(in: databaseDirectories)
    }

    /// The date of the database a scan will actually read.
    ///
    /// `databaseDirectories` is ordered: the first entry is the directory the
    /// bundled `freshclam` writes and `ClamAVScanner` passes as `--database`,
    /// and the Homebrew prefixes after it are fallbacks for dev builds. Only
    /// the first one may vote on freshness — a fresh Homebrew database next to
    /// a stale bundled one would otherwise skip the refresh while the scan ran
    /// against the stale copy.
    private func scannedDatabaseLastUpdateDate() -> Date? {
        guard let scanned = databaseDirectories.first else { return nil }
        return newestSignatureDate(in: [scanned])
    }

    private func newestSignatureDate(in directories: [URL]) -> Date? {
        var newest: Date?
        for directory in directories {
            let entries = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries
            where Self.signatureExtensions.contains(entry.pathExtension.lowercased()) {
                guard
                    let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
                    let modified = attributes[.modificationDate] as? Date
                else { continue }
                if modified > (newest ?? .distantPast) {
                    newest = modified
                }
            }
        }
        return newest
    }

    /// First `freshclam` candidate that is executable, or `nil` when the
    /// updater is not installed.
    func freshclamPath() -> URL? {
        freshclamPaths.first { isExecutable($0.path) }
    }

    /// Runs `freshclam`, forwarding each output line to `progress`. Throws
    /// when `freshclam` is absent or exits non-zero (it returns 0 on both a
    /// successful update and an already-current database).
    func update(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard let executable = freshclamPath() else {
            throw NSError(
                domain: "com.personal.VaderCleaner.DatabaseUpdater",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "freshclam is not installed"]
            )
        }
        let status = try await runner(executable, progress)
        guard status == 0 else {
            throw NSError(
                domain: "com.personal.VaderCleaner.DatabaseUpdater",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "freshclam exited with status \(status)"]
            )
        }
    }

    /// Refreshes the database when it is missing or older than `maxAge`.
    ///
    /// Never throws, which is the point: a scan that can't refresh its
    /// signatures is still worth running against the ones already on disk.
    /// Losing the whole malware result because freshclam couldn't reach the
    /// network would be a worse outcome than scanning slightly behind, so the
    /// failure is logged and the caller carries on. Returns whether a refresh
    /// actually ran and succeeded.
    @discardableResult
    func refreshIfStale(
        now: Date = Date(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Bool {
        if let updated = scannedDatabaseLastUpdateDate(), now.timeIntervalSince(updated) <= Self.maxAge {
            return false
        }
        do {
            try await update(progress: progress)
            return true
        } catch {
            // The error text can name a path freshclam was writing, so it is
            // private like every other error this app logs.
            Self.log.error("Signature refresh failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    // MARK: - Production collaborator

    /// The bundled `freshclam` was compiled with a Homebrew-only default
    /// config path (`/opt/homebrew/etc/clamav/freshclam.conf`) that
    /// doesn't exist on a user machine, so we always pass our own
    /// `--config-file` pointing at the conf `BundledClamAVRuntime`
    /// generated under Application Support.
    static let defaultRunner: FreshclamRunner = { executable, onLine in
        var arguments: [String] = []
        var environment: [String: String]? = nil
        let runtime = BundledClamAVRuntime()
        // The bundled `freshclam` was compiled with Homebrew-only
        // defaults for both the config file and the CVD-signature certs
        // directory; without overrides it errors out before fetching a
        // single byte. We pass our own paths when we have them and
        // fall back silently otherwise so a developer using a Homebrew
        // freshclam still gets the unmodified invocation.
        if let conf = try? runtime.freshclamConfigFile() {
            arguments.append("--config-file=\(conf.path)")
        }
        if let certs = runtime.bundledCVDCertsDirectory() {
            // `--cvdcertsdir` configures freshclam's own download
            // verifier; `CVD_CERTS_DIR` propagates into libclamav's
            // separate "test the freshly-downloaded CVD before saving"
            // verifier, which doesn't read the CLI flag. Setting both
            // covers every code path that loads a `.cvd` file.
            arguments.append("--cvdcertsdir=\(certs.path)")
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
