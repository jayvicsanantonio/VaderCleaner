// DatabaseUpdater.swift
// Reports the ClamAV signature database's last-update time and refreshes it by running freshclam.

import Foundation

/// Tracks and refreshes the ClamAV signature database.
///
/// Homebrew keeps signatures under `<prefix>/var/lib/clamav` as `.cvd`
/// (compressed, full) or `.cld` (incremental) files; their modification
/// time is the most reliable "last updated" signal without parsing
/// `freshclam.log`. Refreshing runs the `freshclam` tool. Database
/// directories, the `freshclam` location, the executable check, and the
/// runner are injected so both queries and updates are unit-testable
/// without a real ClamAV install.
struct DatabaseUpdater {

    typealias ExecutableCheck = (String) -> Bool
    typealias FreshclamRunner = (
        _ executable: URL,
        _ onLine: @escaping (String) -> Void
    ) async throws -> Int32

    /// The signature files freshclam maintains. `.cvd` and `.cld` are the
    /// two on-disk forms of each database; only one of the pair exists at
    /// a time, so all candidates are probed.
    private static let signatureFileNames = [
        "main.cvd", "main.cld",
        "daily.cvd", "daily.cld",
        "bytecode.cvd", "bytecode.cld"
    ]

    private let databaseDirectories: [URL]
    private let freshclamPaths: [URL]
    private let fileManager: FileManager
    private let isExecutable: ExecutableCheck
    private let runner: FreshclamRunner

    init(
        databaseDirectories: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/var/lib/clamav", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/var/lib/clamav", isDirectory: true)
        ],
        freshclamPaths: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/freshclam"),
            URL(fileURLWithPath: "/usr/local/bin/freshclam")
        ],
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

    /// The newest modification date across every signature file in every
    /// configured database directory, or `nil` when none are present
    /// (ClamAV not installed, or `freshclam` never run).
    func lastUpdateDate() -> Date? {
        var newest: Date?
        for directory in databaseDirectories {
            for name in Self.signatureFileNames {
                let path = directory.appendingPathComponent(name).path
                guard
                    let attributes = try? fileManager.attributesOfItem(atPath: path),
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
