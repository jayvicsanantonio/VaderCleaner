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
    /// hermetic (no XPC) unless they wire one in. `reportVisited` receives the
    /// enumerator's own cumulative visited-item count so the scanning screen's
    /// tally keeps climbing through these phases (see `PhaseProgressRelay`).
    /// Optional rather than bare so implementations can forward it into other
    /// escaping `onProgress` parameters.
    typealias PrivilegedEnumerator = @Sendable (_ reportVisited: (@Sendable (Int) -> Void)?) async -> [ScannedFile]

    private let fileScanner: FileScanning
    private let pathProvider: SystemPathProviding
    private let documentVersionsEnumerator: PrivilegedEnumerator
    private let developerProjectEnumerator: PrivilegedEnumerator

    init(
        fileScanner: FileScanning = FileScanner(),
        pathProvider: SystemPathProviding = DefaultSystemPathProvider(),
        documentVersionsEnumerator: @escaping PrivilegedEnumerator = { _ in [] },
        developerProjectEnumerator: @escaping PrivilegedEnumerator = { _ in [] }
    ) {
        self.fileScanner = fileScanner
        self.pathProvider = pathProvider
        self.documentVersionsEnumerator = documentVersionsEnumerator
        self.developerProjectEnumerator = developerProjectEnumerator
    }

    /// Production scanner wired to enumerate the Document Versions store through
    /// the privileged helper and the scattered web/dev project folders through
    /// `DeveloperProjectScanner`. Used by the Cleanup section and Smart Scan so
    /// both surface the same junk categories.
    ///
    /// `projectScanRoots` defaults to the user's saved Web Development Junk scope
    /// (`WebDevScanScopeStore`); callers that own a live scope store pass its
    /// roots so a freshly-picked folder takes effect on the next scan.
    @MainActor
    static func live(projectScanRoots: [URL]? = nil) -> SystemJunkScanner {
        let roots = projectScanRoots ?? WebDevScanScopeStore().scanRoots
        return SystemJunkScanner(
            // The store is enumerated in one privileged XPC round trip, so
            // the best available progress is a single bump by the returned
            // count once it lands.
            documentVersionsEnumerator: { reportVisited in
                let files = await DocumentVersionsScanner().scan()
                reportVisited?(files.count)
                return files
            },
            developerProjectEnumerator: { reportVisited in
                await DeveloperProjectScanner(roots: roots).scan(onProgress: reportVisited)
            }
        )
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
        // One walked-count spans all three phases: the relay stacks each
        // phase's own tally onto the finished phases' totals, so the count
        // the scanning screen shows keeps climbing through the supplementary
        // enumerations instead of freezing when the main walk completes.
        let progress = PhaseProgressRelay(onProgress)
        let files = try await fileScanner.scan(
            roots: roots,
            excluding: excluding,
            onProgress: { progress.report($0) }
        )
        progress.finishPhase()
        // Document Versions live in a root-owned store the in-process walk can't
        // read, so they come from the privileged enumerator and are merged in.
        // The default enumerator returns nothing, so this is a no-op unless the
        // production scanner wired one in.
        let documentVersions = await documentVersionsEnumerator { progress.report($0) }
        progress.finishPhase()
        // Scattered web/dev project artifacts (node_modules, dist, …) live at
        // arbitrary depths under the user's code directories, so they come from
        // the developer-project enumerator rather than a fixed scan root. The
        // default enumerator returns nothing, so this is a no-op unless the
        // production scanner wired one in.
        let developerProjects = await developerProjectEnumerator { progress.report($0) }
        return ScanResult(items: files + documentVersions + developerProjects)
    }
}

/// Stacks each scan phase's own cumulative walked-count onto the totals of
/// the phases already finished, forwarding one ever-climbing number to the
/// caller's `onProgress`. Each phase counts from zero in its own terms;
/// without the relay, the hand-off from the main walk to the supplementary
/// enumerators would reset (or freeze) the count the scanning screen shows.
/// Thread-safe because phases report from their own tasks.
private final class PhaseProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var completedPhasesTotal = 0
    private var currentPhaseCount = 0
    private let onProgress: (@Sendable (Int) -> Void)?

    init(_ onProgress: (@Sendable (Int) -> Void)?) {
        self.onProgress = onProgress
    }

    /// Reports the running phase's own cumulative count, forwarding the
    /// all-phases total. Kept monotonic within the phase so an out-of-order
    /// tick can't move the number backwards.
    func report(_ count: Int) {
        lock.lock()
        currentPhaseCount = max(currentPhaseCount, count)
        let total = completedPhasesTotal + currentPhaseCount
        lock.unlock()
        onProgress?(total)
    }

    /// Seals the finished phase's tally into the running base before the next
    /// phase starts its own count from zero.
    func finishPhase() {
        lock.lock()
        completedPhasesTotal += currentPhaseCount
        currentPhaseCount = 0
        lock.unlock()
    }
}
