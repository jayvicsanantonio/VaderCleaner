// DatabaseUpdater.swift
// Reports the ClamAV signature database's last-update time and refreshes it by running freshclam.

import Foundation

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
struct DatabaseUpdater {

    typealias ExecutableCheck = (String) -> Bool
    typealias FreshclamRunner = (
        _ executable: URL,
        _ onLine: @escaping (String) -> Void
    ) async throws -> Int32

    /// The two on-disk forms of a ClamAV signature database. `freshclam`
    /// keeps `main`, `daily`, and `bytecode` plus optional extras
    /// (`safebrowsing`, third-party feeds), so the directory is scanned by
    /// extension rather than against a fixed filename list — a hardcoded
    /// list would miss extra databases and report a stale last-update time.
    private static let signatureExtensions: Set<String> = ["cvd", "cld"]

    private let databaseDirectories: [URL]
    private let freshclamPaths: [URL]
    private let fileManager: FileManager
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

    /// Returns candidate database directories, checking the bundled ClamAV
    /// first, then falling back to Homebrew prefixes.
    static func defaultDatabaseDirectories() -> [URL] {
        var paths: [URL] = []
        
        // 1. Bundled ClamAV database (staged by Scripts/stage-clamav.sh)
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("clamav/share/clamav", isDirectory: true) {
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
        var newest: Date?
        for directory in databaseDirectories {
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
                if newest == nil || modified > newest! {
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
    func update(progress: @escaping (String) -> Void = { _ in }) async throws {
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

    // MARK: - Production collaborator

    static let defaultRunner: FreshclamRunner = { executable, onLine in
        try await ProcessLineStreamer.run(
            executable: executable,
            arguments: [],
            onLine: onLine
        )
    }
}
