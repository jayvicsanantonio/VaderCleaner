// ClamAVDetector.swift
// Locates a bundled or Homebrew-installed clamscan binary and reports its version.

import Foundation

/// Discovers whether ClamAV's `clamscan` is installed and, if so, where.
///
/// VaderCleaner checks for a bundled ClamAV first (staged by the build
/// script into `Resources/clamav/bin`), then falls back to a Homebrew
/// install living at one of the standard prefixes (`/opt/homebrew` on
/// Apple silicon, `/usr/local` on Intel). The candidate paths, the
/// executable-file check, and the `--version` runner are all injected so
/// detection is unit-testable without a real install.
struct ClamAVDetector {

    typealias ExecutableCheck = (String) -> Bool
    typealias VersionRunner = (URL) async -> String?

    private let candidatePaths: [URL]
    private let isExecutable: ExecutableCheck
    private let versionRunner: VersionRunner

    init(
        candidatePaths: [URL] = ClamAVDetector.defaultCandidatePaths(),
        isExecutable: @escaping ExecutableCheck = { FileManager.default.isExecutableFile(atPath: $0) },
        versionRunner: @escaping VersionRunner = ClamAVDetector.defaultVersionRunner
    ) {
        self.candidatePaths = candidatePaths
        self.isExecutable = isExecutable
        self.versionRunner = versionRunner
    }

    // MARK: - Default Paths

    /// Returns candidate `clamscan` paths, checking the app bundle first (so a
    /// bundled ClamAV wins), then falling back to Homebrew prefixes.
    static func defaultCandidatePaths() -> [URL] {
        var paths: [URL] = []
        
        // 1. Bundled ClamAV (staged by Scripts/stage-clamav.sh)
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("clamav/bin/clamscan", isDirectory: false) {
            paths.append(bundled)
        }
        
        // 2. Homebrew on Apple silicon
        paths.append(URL(fileURLWithPath: "/opt/homebrew/bin/clamscan"))
        
        // 3. Homebrew on Intel
        paths.append(URL(fileURLWithPath: "/usr/local/bin/clamscan"))
        
        return paths
    }

    /// The first candidate that is an executable file, or `nil` when none
    /// resolve — i.e. ClamAV is not installed.
    func path() -> URL? {
        candidatePaths.first { isExecutable($0.path) }
    }

    func isInstalled() -> Bool {
        path() != nil
    }

    /// Runs `clamscan --version` and returns its trimmed banner
    /// ("ClamAV 1.4.1/27000/..."), or `nil` when ClamAV is absent or the
    /// binary produced no output.
    func version() async -> String? {
        guard let binary = path() else { return nil }
        guard let raw = await versionRunner(binary) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Production collaborator

    /// Runs `clamscan --version` off the calling thread. stdout is read
    /// before `waitUntilExit()` and stderr is discarded so a chatty binary
    /// can't deadlock on a full pipe buffer — the same discipline used by
    /// `LaunchAgentManager.defaultLoadedLabels`.
    static let defaultVersionRunner: VersionRunner = { binary in
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8)
            } catch {
                return nil
            }
        }.value
    }
}
