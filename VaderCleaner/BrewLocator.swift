// BrewLocator.swift
// Resolves the Homebrew `brew` executable across the standard Apple-silicon and Intel prefixes, or reports its absence.

import Foundation

/// Test seam for locating the `brew` executable. Returns `nil` when Homebrew is
/// not installed, which drives the manager's "Homebrew not installed" state.
protocol BrewLocating: Sendable {
    func locate() -> URL?
}

/// Production locator — probes the standard Homebrew prefixes in order
/// (Apple silicon first, then Intel) and returns the first that is an
/// executable file. Candidate paths and the executable check are injected so
/// detection is unit-testable without a real install, mirroring
/// `ClamAVDetector`.
struct DefaultBrewLocator: BrewLocating {

    typealias ExecutableCheck = @Sendable (String) -> Bool

    private let candidates: [URL]
    private let isExecutable: ExecutableCheck

    init(
        candidates: [URL] = DefaultBrewLocator.defaultCandidates(),
        isExecutable: @escaping ExecutableCheck = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    /// The standard `brew` locations: `/opt/homebrew` on Apple silicon,
    /// `/usr/local` on Intel — the same prefixes `ClamAVDetector` falls back to.
    static func defaultCandidates() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew"),
        ]
    }

    func locate() -> URL? {
        candidates.first { isExecutable($0.path) }
    }
}
