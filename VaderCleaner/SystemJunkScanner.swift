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

    /// Source of extra `ScannedFile`s that can't be read by the in-process
    /// `FileScanner` and must come from the privileged helper — currently the
    /// root-owned Document Versions store. Async + `@Sendable` so production can
    /// wrap `DocumentVersionsScanner`; the default is a no-op so unit tests stay
    /// hermetic (no XPC) unless they wire one in.
    typealias PrivilegedEnumerator = @Sendable () async -> [ScannedFile]

    private let fileScanner: FileScanning
    private let pathProvider: SystemPathProviding
    private let documentVersionsEnumerator: PrivilegedEnumerator

    init(
        fileScanner: FileScanning = FileScanner(),
        pathProvider: SystemPathProviding = DefaultSystemPathProvider(),
        documentVersionsEnumerator: @escaping PrivilegedEnumerator = { [] }
    ) {
        self.fileScanner = fileScanner
        self.pathProvider = pathProvider
        self.documentVersionsEnumerator = documentVersionsEnumerator
    }

    /// Production scanner wired to enumerate the Document Versions store through
    /// the privileged helper. Used by the Cleanup section and Smart Scan so both
    /// surface the same junk categories.
    static func live() -> SystemJunkScanner {
        SystemJunkScanner(documentVersionsEnumerator: { await DocumentVersionsScanner().scan() })
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
        // Document Versions live in a root-owned store the in-process walk can't
        // read, so they come from the privileged enumerator and are merged in.
        // The default enumerator returns nothing, so this is a no-op unless the
        // production scanner wired one in.
        let documentVersions = await documentVersionsEnumerator()
        return ScanResult(items: files + documentVersions)
    }
}
