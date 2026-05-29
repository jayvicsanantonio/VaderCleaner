// SystemJunkScanner.swift
// Orchestrator that asks SystemPathProviding for category-tagged roots, runs FileScanner over them, and packages the output as a ScanResult.

import Foundation

/// Top-level entry point for the System Junk feature. Composes a
/// `SystemPathProviding` (which knows where macOS keeps caches, logs,
/// trash, iOS backups, mail attachments, and stale `.lproj` bundles) with a
/// `FileScanning` (which does the actual recursive walk) and returns a
/// `ScanResult` keyed by `ScanCategory`.
///
/// The scanner itself owns no path knowledge — that lives entirely in the
/// path provider — so tests inject a stub that returns roots under a temp
/// directory and exercise every code path without touching real system
/// locations.
///
/// Privileged-helper-driven enumeration of `/Library/Caches` and
/// `/Library/Logs` is deferred to Prompt 14 where it pairs with deletion.
/// With Full Disk Access (granted via Prompt 4) the in-process walk reads
/// these paths today; `FileScanner`'s permission-error tolerance handles
/// any locked descendants.
struct SystemJunkScanner {

    private let fileScanner: FileScanning
    private let pathProvider: SystemPathProviding

    init(
        fileScanner: FileScanning = FileScanner(),
        pathProvider: SystemPathProviding = DefaultSystemPathProvider()
    ) {
        self.fileScanner = fileScanner
        self.pathProvider = pathProvider
    }

    /// Runs the scan and returns aggregated results. `excluding` is forwarded
    /// straight to `FileScanner` — the path-component-aware match semantics
    /// (covered in `FileScannerTests`) apply unchanged here, so a user who
    /// excluded `~/Library/Caches/com.apple.Safari` will see Safari's caches
    /// disappear from every category their parent path falls under.
    func scan(
        excluding: [URL],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ScanResult {
        let roots = pathProvider.roots()
        let files = try await fileScanner.scan(roots: roots, excluding: excluding, onProgress: onProgress)
        return ScanResult(items: files)
    }
}
