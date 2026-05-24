// SmartScanViewModel.swift
// State machine behind the Smart Scan feature view — orchestrates the System Junk, Malware, and Optimization sub-modules into one concurrent scan, aggregates their results, and drives a single junk+threats clean pass.

import AppKit
import Foundation
import os.log

/// The five tiles the Smart Scan dashboard renders, one per orchestrated
/// sub-module. The enum drives both the rendering loop and the per-tile
/// selection set the user toggles on the dashboard. The case order mirrors
/// the left-to-right reading order on the dashboard so iterating
/// `allCases` lays the tiles out the same way the reference does.
enum SmartScanModule: Hashable, CaseIterable {
    case systemJunk
    case malware
    case optimization
    case applications
    case myClutter
}

/// One aggregated Smart Scan result, holding each sub-module's findings so the
/// results screen can render a card per module. `clamAVAvailable` lets the
/// Malware card hide its remove action when ClamAV is absent (the scan was
/// skipped, so an empty `threats` list there is "unknown", not "clean").
struct SmartScanResult: Equatable {
    let junkResult: ScanResult
    let threats: [MalwareThreat]
    let optimizationItems: [LoginItem]
    /// Files surfaced by the Large & Old Files sub-scan, fronting the
    /// "My Clutter" tile on the dashboard. Empty when the scan found nothing
    /// — or, in live wiring, when the underlying scanner failed (failures are
    /// swallowed to `[]` so one bad probe never sinks an otherwise-useful
    /// Smart Scan).
    let largeOldFiles: [ScannedFile]
    /// Per-app updates surfaced by the App Updater sub-check, fronting the
    /// "Applications" tile. Same partial-degradation contract as `threats`
    /// and `largeOldFiles` — a network failure yields `[]`, not `.failed`.
    let availableUpdates: [UpdateInfo]
    let clamAVAvailable: Bool

    /// "Total bytes found" is the System Junk byte total: detected threats and
    /// login items don't correspond to freeable bytes, so they don't
    /// contribute. Named explicitly so the contract is unambiguous.
    var totalJunkBytes: Int64 { junkResult.totalSize }
}

/// What a Smart Scan Run pass accomplished, aggregated across every tile
/// the user kept selected. The done screen reads each field and renders a
/// matching clause — zero-valued fields are dropped from the line so the
/// summary only mentions work that actually happened.
///
/// `failedModules` is non-empty when a per-module catch fired during Run.
/// Per Open Decision 1 in the plan, a single module's failure must not
/// collapse the whole pass to `.failed` — every other module's work is
/// preserved, and the failure surfaces as a warning under the headline
/// summary rather than as an error screen.
struct SmartScanSummary: Equatable {
    /// Bytes the System Junk cleaner reported as freed.
    let bytesFreed: Int64
    /// Threats the Malware remover successfully removed (i.e. were
    /// requested *and* not returned as failures by the remover).
    let threatsRemoved: Int
    /// The Maintenance script runner's result line on success, `nil` if
    /// Optimization was deselected or the runner threw.
    let maintenanceOutput: String?
    /// How many app-update URLs Run opened via the App Updater opener.
    let updatesOpened: Int
    /// How many large-old files the My Clutter deleter actually removed
    /// (partial-success: the deleter reports only the URLs whose removal
    /// succeeded).
    let clutterFilesRemoved: Int
    /// Sum of `ScannedFile.size` for the files actually removed — useful
    /// because the done line wants a byte-style figure to show alongside
    /// the count.
    let clutterBytesRemoved: Int64
    /// Modules whose per-module catch fired during Run. The done screen
    /// uses this to surface a warning clause without collapsing the whole
    /// pass.
    let failedModules: Set<SmartScanModule>

    /// Convenience for the original two-field call sites — every other
    /// field defaults so existing tests and previews don't have to spell
    /// out the entire aggregate when they only care about junk + threats.
    init(
        bytesFreed: Int64,
        threatsRemoved: Int,
        maintenanceOutput: String? = nil,
        updatesOpened: Int = 0,
        clutterFilesRemoved: Int = 0,
        clutterBytesRemoved: Int64 = 0,
        failedModules: Set<SmartScanModule> = []
    ) {
        self.bytesFreed = bytesFreed
        self.threatsRemoved = threatsRemoved
        self.maintenanceOutput = maintenanceOutput
        self.updatesOpened = updatesOpened
        self.clutterFilesRemoved = clutterFilesRemoved
        self.clutterBytesRemoved = clutterBytesRemoved
        self.failedModules = failedModules
    }
}

/// Drives the Smart Scan feature view (scan → results → clean → done).
/// Collaborators are injected as closures — each mirrors the contract of the
/// sub-module it fronts — so unit tests can exercise every transition without
/// touching the real filesystem, ClamAV, or the privileged helper. Production
/// wiring lives in `SmartScanViewModel.live(exclusions:)`.
@MainActor
final class SmartScanViewModel: ObservableObject {

    /// Discrete phases the view binds to. The happy path is
    /// `idle → scanning → results → cleaning → done`; `failed` carries a
    /// message to surface.
    enum Phase: Equatable {
        case idle
        case scanning(phase: String)
        case results(SmartScanResult)
        case cleaning
        case done(summary: SmartScanSummary)
        case failed(message: String)
    }

    /// System Junk scan source. Throwing: a failed junk scan fails the whole
    /// Smart Scan, mirroring `SystemJunkViewModel.Scanner`.
    typealias JunkScanner = () async throws -> ScanResult
    /// Whether ClamAV is installed. When `false` the malware scan is skipped
    /// entirely and the Malware card hides its action.
    typealias MalwareInstalled = () -> Bool
    /// Malware scan source. Non-throwing and best-effort: a broken ClamAV
    /// install must not fail an otherwise-useful Smart Scan, so the live
    /// wiring logs and yields `[]` rather than propagating.
    typealias MalwareScanner = () async -> [MalwareThreat]
    /// Login-item loader, mirroring `OptimizationViewModel.LoadLoginItems`.
    typealias LoginItemsLoader = () async -> [LoginItem]
    /// Large & Old Files scan source, fronting the My Clutter tile. Non-
    /// throwing and best-effort: a partly-blocked filesystem walk must not
    /// fail the whole Smart Scan, so the live wiring catches and yields `[]`
    /// (same shape as the malware sub-scan). Named `ClutterScanner` rather
    /// than `LargeOldFilesScanner` to keep the typealias from colliding
    /// with the underlying `LargeOldFilesScanner` *class* in `.live`.
    typealias ClutterScanner = () async -> [ScannedFile]
    /// App-update check source, fronting the Applications tile. Non-throwing
    /// and best-effort for the same reason as `ClutterScanner` — a
    /// network blip can't sink an otherwise-useful Smart Scan.
    typealias UpdatesChecker = () async -> [UpdateInfo]
    /// Junk deletion sink — returns the bytes actually freed, mirroring
    /// `SystemJunkViewModel.Deleter`.
    typealias JunkCleaner = ([ScannedFile]) async throws -> Int64
    /// Threat remover — returns the threats it could **not** remove (empty ==
    /// full success), mirroring `MalwareViewModel.RemoveThreats`.
    typealias ThreatRemover = ([MalwareThreat]) async -> [MalwareThreat]
    /// Privileged maintenance-script runner, mirroring
    /// `OptimizationViewModel.RunMaintenance` — returns a result line on
    /// success and throws on a dropped helper connection or a script failure.
    typealias MaintenanceRunner = () async throws -> String
    /// Opens an App Updater update URL (App Store or Sparkle), mirroring the
    /// per-app opener that `AppUpdaterViewModel` already routes through
    /// `NSWorkspace.open`. Non-throwing — open is fire-and-forget.
    typealias UpdateOpener = (URL) async -> Void
    /// Removes the given large-old file URLs and returns the set of URLs that
    /// were actually removed. Mirrors `LargeOldFilesViewModel.Deleter`:
    /// partial-success is the norm (a single locked file must not abort the
    /// batch), so the return is the success set, not a failure set.
    typealias LargeFileDeleter = ([URL]) async -> Set<URL>

    @Published private(set) var phase: Phase = .idle

    /// Which tiles on the dashboard are checked. Empty at `.idle`; seeded on
    /// the `.scanning → .results` transition to "every module that has
    /// actionable work" (matching the reference's default-all-on behavior),
    /// and cleared again on `reset()`. The Run pass iterates this set so a
    /// deselected tile is skipped entirely.
    @Published private(set) var tileSelection: Set<SmartScanModule> = []

    /// Per-category gate inside the System Junk tile's Review screen. Seeded
    /// to every category that actually has items in `result.junkResult`, so
    /// the default-all-on behavior matches the reference's manager view.
    @Published private(set) var junkCategorySelection: Set<ScanCategory> = []

    /// Per-threat gate inside the Malware tile's Review screen, keyed by
    /// `MalwareThreat.filePath`. Seeded to every detected threat. Run filters
    /// the threat list down to this set before handing it to the remover.
    @Published private(set) var threatSelection: Set<URL> = []

    /// Per-update gate inside the Applications tile's Review screen, keyed by
    /// `UpdateInfo.bundleID`. Seeded to every available update; Run hands the
    /// selected updates to the opener one by one.
    @Published private(set) var updateSelection: Set<String> = []

    /// Per-file gate inside the My Clutter tile's Review screen, keyed by
    /// `ScannedFile.url`. Seeded *empty* — large-file deletion is destructive
    /// and irreversible, so parity with `LargeOldFilesViewModel` requires the
    /// user to opt each file in explicitly before Run can remove it.
    @Published private(set) var largeFileSelection: Set<URL> = []

    /// `result.largeOldFiles` pre-sorted by size descending, so the My
    /// Clutter Review's list reads "biggest forgotten thing first" without
    /// the view re-sorting on every body re-evaluation. Recomputed once
    /// when results land; cleared on `reset()`.
    @Published private(set) var sortedLargeOldFiles: [ScannedFile] = []

    private let junkScanner: JunkScanner
    private let malwareInstalled: MalwareInstalled
    private let malwareScanner: MalwareScanner
    private let loginItemsLoader: LoginItemsLoader
    private let largeOldFilesScanner: ClutterScanner
    private let updatesChecker: UpdatesChecker
    private let junkCleaner: JunkCleaner
    private let threatRemover: ThreatRemover
    private let maintenanceRunner: MaintenanceRunner
    private let updateOpener: UpdateOpener
    private let largeFileDeleter: LargeFileDeleter

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "SmartScanViewModel")

    init(
        junkScanner: @escaping JunkScanner,
        malwareInstalled: @escaping MalwareInstalled,
        malwareScanner: @escaping MalwareScanner,
        loginItemsLoader: @escaping LoginItemsLoader,
        largeOldFilesScanner: @escaping ClutterScanner,
        updatesChecker: @escaping UpdatesChecker,
        junkCleaner: @escaping JunkCleaner,
        threatRemover: @escaping ThreatRemover,
        maintenanceRunner: @escaping MaintenanceRunner,
        updateOpener: @escaping UpdateOpener,
        largeFileDeleter: @escaping LargeFileDeleter
    ) {
        self.junkScanner = junkScanner
        self.malwareInstalled = malwareInstalled
        self.malwareScanner = malwareScanner
        self.loginItemsLoader = loginItemsLoader
        self.largeOldFilesScanner = largeOldFilesScanner
        self.updatesChecker = updatesChecker
        self.junkCleaner = junkCleaner
        self.threatRemover = threatRemover
        self.maintenanceRunner = maintenanceRunner
        self.updateOpener = updateOpener
        self.largeFileDeleter = largeFileDeleter
    }

    // MARK: - Scan

    /// Runs the three sub-scans concurrently and lands `.results` (or
    /// `.failed` if the junk scan throws). The ClamAV install check is read
    /// once up front so the result can record whether the malware scan was
    /// actually performed.
    ///
    /// Re-entrant calls while a scan or clean is already in flight are
    /// ignored, so a double-tap (or a programmatic caller) can't leave two
    /// scans racing the `phase` updates. The guard is read synchronously
    /// before the first `await`, so it is reliable under `@MainActor`.
    func scan() async {
        switch phase {
        case .scanning, .cleaning:
            return
        case .idle, .results, .done, .failed:
            break
        }

        phase = .scanning(phase: String(
            localized: "Scanning for junk, malware, and optimization opportunities…",
            comment: "Progress label shown while the Smart Scan runs all sub-scans."
        ))

        let clamAVAvailable = malwareInstalled()

        async let junk = junkScanner()
        async let threats = scanForThreatsIfPossible(clamAVAvailable: clamAVAvailable)
        async let login = loginItemsLoader()
        async let large = largeOldFilesScanner()
        async let updates = updatesChecker()

        do {
            let junkResult = try await junk
            let foundThreats = await threats
            let loginItems = await login
            let largeFiles = await large
            let foundUpdates = await updates

            let result = SmartScanResult(
                junkResult: junkResult,
                threats: foundThreats,
                optimizationItems: loginItems,
                largeOldFiles: largeFiles,
                availableUpdates: foundUpdates,
                clamAVAvailable: clamAVAvailable
            )
            tileSelection = Self.defaultTileSelection(for: result)
            junkCategorySelection = Set(result.junkResult.itemsByCategory.keys)
            threatSelection = Set(foundThreats.map(\.filePath))
            updateSelection = Set(foundUpdates.map(\.bundleID))
            // largeFileSelection stays empty — parity with
            // `LargeOldFilesViewModel` (destructive deletes are opt-in).
            largeFileSelection = []
            // Sort once here so the Review list doesn't re-sort on every
            // SwiftUI body re-eval as the user toggles individual files.
            sortedLargeOldFiles = largeFiles.sorted { $0.size > $1.size }
            phase = .results(result)
        } catch {
            log.error("Smart Scan failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Runs the malware scan only when ClamAV is present. Factored out of
    /// `scan()` so the `async let` site stays readable and the gating logic
    /// isn't buried in a conditional async closure.
    private func scanForThreatsIfPossible(clamAVAvailable: Bool) async -> [MalwareThreat] {
        guard clamAVAvailable else { return [] }
        return await malwareScanner()
    }

    // MARK: - Run

    /// Single Run pass over the latest results, gated by `tileSelection` and
    /// the per-tile sub-selections. A deselected tile is skipped entirely;
    /// within a selected tile, items the user deselected via Review are
    /// filtered out before the collaborator is called. Each module's work
    /// runs inside its own do/catch (Open Decision 1 in the plan) so a
    /// single module's failure leaves every other module's results intact —
    /// failures are recorded in `summary.failedModules` instead of
    /// collapsing the whole pass to `.failed`.
    /// A no-op unless we are showing results.
    func run() async {
        guard case .results(let result) = phase else { return }
        phase = .cleaning

        var bytesFreed: Int64 = 0
        var threatsRemoved = 0
        var maintenanceOutput: String? = nil
        var updatesOpened = 0
        var clutterFilesRemoved = 0
        var clutterBytesRemoved: Int64 = 0
        var failedModules: Set<SmartScanModule> = []

        if tileSelection.contains(.systemJunk) {
            // O(selected categories) flatten via the pre-grouped dictionary
            // rather than O(all junk files) filter on the flat `items`
            // array. System Junk scans routinely surface tens of thousands
            // of files; filtering on the main actor used to stutter the
            // "Running…" indicator.
            let selectedJunk = junkCategorySelection
                .compactMap { result.junkResult.itemsByCategory[$0] }
                .flatMap { $0 }
            if !selectedJunk.isEmpty {
                do {
                    bytesFreed = try await junkCleaner(selectedJunk)
                } catch {
                    log.error("Smart Scan junk clean failed: \(String(describing: error), privacy: .public)")
                    failedModules.insert(.systemJunk)
                }
            }
        }

        if tileSelection.contains(.malware) {
            let selectedThreats = result.threats.filter {
                threatSelection.contains($0.filePath)
            }
            if !selectedThreats.isEmpty {
                let failures = await threatRemover(selectedThreats)
                threatsRemoved = selectedThreats.count - failures.count
                if !failures.isEmpty {
                    log.error("\(failures.count, privacy: .public) of \(selectedThreats.count, privacy: .public) threats could not be removed during Smart Scan run")
                    failedModules.insert(.malware)
                }
            }
        }

        if tileSelection.contains(.optimization) {
            do {
                maintenanceOutput = try await maintenanceRunner()
            } catch {
                log.error("Smart Scan maintenance failed: \(String(describing: error), privacy: .public)")
                failedModules.insert(.optimization)
            }
        }

        if tileSelection.contains(.applications) {
            let selectedUpdates = result.availableUpdates.filter {
                updateSelection.contains($0.bundleID)
            }
            for update in selectedUpdates {
                await updateOpener(update.updateURL)
                updatesOpened += 1
            }
        }

        if tileSelection.contains(.myClutter), !largeFileSelection.isEmpty {
            let urls = Array(largeFileSelection)
            let removed = await largeFileDeleter(urls)
            clutterFilesRemoved = removed.count
            // Walk the scan's recorded file list to total bytes the deleter
            // actually freed, since the deleter only reports URLs.
            clutterBytesRemoved = result.largeOldFiles
                .filter { removed.contains($0.url) }
                .reduce(Int64(0)) { $0 + $1.size }
            if removed.count < urls.count {
                log.error("\(urls.count - removed.count, privacy: .public) of \(urls.count, privacy: .public) clutter files could not be removed during Smart Scan run")
                failedModules.insert(.myClutter)
            }
        }

        phase = .done(summary: SmartScanSummary(
            bytesFreed: bytesFreed,
            threatsRemoved: threatsRemoved,
            maintenanceOutput: maintenanceOutput,
            updatesOpened: updatesOpened,
            clutterFilesRemoved: clutterFilesRemoved,
            clutterBytesRemoved: clutterBytesRemoved,
            failedModules: failedModules
        ))
    }

    // MARK: - Tile selection

    /// Whether the given module's tile is currently checked on the dashboard.
    func isModuleSelected(_ module: SmartScanModule) -> Bool {
        tileSelection.contains(module)
    }

    /// Flips the given module's checked state on the dashboard. A no-op-safe
    /// add/remove on the published set so SwiftUI's `Toggle` can bind through
    /// a synthesized `Binding`.
    func toggleModule(_ module: SmartScanModule) {
        if tileSelection.contains(module) {
            tileSelection.remove(module)
        } else {
            tileSelection.insert(module)
        }
    }

    // MARK: - Sub-selections (per-tile Review screens)

    func isJunkCategorySelected(_ category: ScanCategory) -> Bool {
        junkCategorySelection.contains(category)
    }

    func toggleJunkCategory(_ category: ScanCategory) {
        if junkCategorySelection.contains(category) {
            junkCategorySelection.remove(category)
        } else {
            junkCategorySelection.insert(category)
        }
    }

    func isThreatSelected(_ threat: MalwareThreat) -> Bool {
        threatSelection.contains(threat.filePath)
    }

    func toggleThreat(_ threat: MalwareThreat) {
        if threatSelection.contains(threat.filePath) {
            threatSelection.remove(threat.filePath)
        } else {
            threatSelection.insert(threat.filePath)
        }
    }

    func isUpdateSelected(_ update: UpdateInfo) -> Bool {
        updateSelection.contains(update.bundleID)
    }

    func toggleUpdate(_ update: UpdateInfo) {
        if updateSelection.contains(update.bundleID) {
            updateSelection.remove(update.bundleID)
        } else {
            updateSelection.insert(update.bundleID)
        }
    }

    func isLargeFileSelected(_ file: ScannedFile) -> Bool {
        largeFileSelection.contains(file.url)
    }

    func toggleLargeFile(_ file: ScannedFile) {
        if largeFileSelection.contains(file.url) {
            largeFileSelection.remove(file.url)
        } else {
            largeFileSelection.insert(file.url)
        }
    }

    /// Opt every detected large/old file in for removal in one write to
    /// `largeFileSelection`. Done as a single set assignment so SwiftUI
    /// observes one publish instead of N (one per `toggleLargeFile` call),
    /// which on large clutter scans would otherwise stall the UI behind
    /// the cascade of refreshes.
    func selectAllLargeFiles() {
        guard case .results(let result) = phase else { return }
        largeFileSelection = Set(result.largeOldFiles.map(\.url))
    }

    /// Opt every file back out — single-write counterpart to
    /// `selectAllLargeFiles()`.
    func clearLargeFileSelection() {
        largeFileSelection = []
    }

    // MARK: - Executable work surface

    /// Whether the given module would actually produce work if Run were
    /// pressed right now. The tile must be selected, *and* its sub-selection
    /// must filter down to at least one item. Optimization is the exception
    /// — its action is to run the system maintenance scripts, which is
    /// always available, so being selected is sufficient.
    ///
    /// Read by both the dashboard's per-tile caption decisions and the
    /// floating Run disc's visibility gate, so the two surfaces share one
    /// source of truth.
    func willExecute(_ module: SmartScanModule) -> Bool {
        guard case .results(let result) = phase else { return false }
        guard isModuleSelected(module) else { return false }
        switch module {
        case .systemJunk:
            // O(min(selected categories, categories-with-items)) intersection
            // on the pre-grouped dictionary's keys rather than O(all files).
            // `hasExecutableWork` calls this on every SwiftUI refresh, so
            // the cheaper check matters under heavy junk scans.
            return !junkCategorySelection
                .intersection(result.junkResult.itemsByCategory.keys)
                .isEmpty
        case .malware:
            return result.threats.contains {
                threatSelection.contains($0.filePath)
            }
        case .optimization:
            return true
        case .applications:
            return result.availableUpdates.contains {
                updateSelection.contains($0.bundleID)
            }
        case .myClutter:
            return !largeFileSelection.isEmpty
        }
    }

    /// `true` iff at least one selected module would actually do work
    /// during Run. The floating Run disc gates its visibility on this — a
    /// disc whose Run wouldn't execute anything reads as a no-op trap.
    var hasExecutableWork: Bool {
        SmartScanModule.allCases.contains { willExecute($0) }
    }

    /// Default tile-selection seed for a freshly-landed `.results` payload.
    /// A module starts checked iff it has actionable work for Run. Optimization
    /// is *always* on because its action — running the system maintenance
    /// scripts — is available on every macOS install (there is nothing to
    /// "find" the way junk or threats are found). The user can still
    /// deselect it on the dashboard.
    private static func defaultTileSelection(for result: SmartScanResult) -> Set<SmartScanModule> {
        var selection: Set<SmartScanModule> = [.optimization]
        if result.totalJunkBytes > 0 { selection.insert(.systemJunk) }
        if !result.threats.isEmpty { selection.insert(.malware) }
        if !result.availableUpdates.isEmpty { selection.insert(.applications) }
        if !result.largeOldFiles.isEmpty { selection.insert(.myClutter) }
        return selection
    }

    // MARK: - Recovery

    /// Returns to idle from a terminal phase so the user can start over.
    /// Tile selection clears in lockstep so a fresh scan starts from the
    /// default-all-on seed rather than carrying the previous user's
    /// deselections forward.
    func reset() {
        phase = .idle
        tileSelection = []
        junkCategorySelection = []
        threatSelection = []
        updateSelection = []
        largeFileSelection = []
        sortedLargeOldFiles = []
    }
}

// MARK: - Production wiring

extension SmartScanViewModel {

    /// Builds a view-model wired to the real System Junk scanner/deleter, the
    /// ClamAV detector/scanner, the malware threat remover, the login-item
    /// manager, the Large & Old Files scanner/deleter, the App Updater
    /// discovery + per-channel checkers, the privileged maintenance-script
    /// runner, and `NSWorkspace.open` for opening update URLs — the same
    /// collaborators the individual feature `.live()` factories use, so
    /// Smart Scan and the standalone sections never diverge.
    ///
    /// The exclusions snapshot is captured per scan so a freshly-added
    /// Preferences exclusion takes effect on the next run, matching
    /// `SystemJunkViewModel.live`.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> SmartScanViewModel {
        let detector = ClamAVDetector()
        let scanner = ClamAVScanner(detector: detector)
        let remover = MalwareThreatRemover()
        let loginManager = LoginItemsManager.live()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SmartScanViewModel.live")

        return SmartScanViewModel(
            junkScanner: { [weak exclusions] in
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                return try await SystemJunkScanner().scan(excluding: excluded)
            },
            malwareInstalled: { detector.isInstalled() },
            // Best-effort: a missing signature database or a broken clamscan
            // binary must not sink an otherwise-useful Smart Scan. We log the
            // failure (rather than swallow it silently) so an unexpectedly
            // empty Malware card is debuggable, then degrade to "no threats".
            malwareScanner: {
                do {
                    return try await scanner.scan(paths: [home], progress: { _ in })
                } catch {
                    log.error("Smart Scan malware sub-scan failed, treating as no threats: \(String(describing: error), privacy: .public)")
                    return []
                }
            },
            loginItemsLoader: { loginManager.items() },
            // Same `LargeOldFilesScanner` the standalone Large & Old Files
            // section uses. A partly-blocked filesystem walk must not sink
            // the whole Smart Scan, so failures are logged and degraded to
            // an empty list (same partial-degradation contract as the
            // malware scanner above).
            largeOldFilesScanner: { [weak exclusions] in
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                do {
                    return try await LargeOldFilesScanner().scan(excluding: excluded)
                } catch {
                    log.error("Smart Scan large/old files sub-scan failed, treating as no files: \(String(describing: error), privacy: .public)")
                    return []
                }
            },
            // App Updater wiring: discover installed apps, then fan out
            // per-app version probes against the App Store and Sparkle
            // channels. The underlying collaborators (`DefaultAppDiscovery`,
            // `DefaultAppStoreUpdateChecker`, `DefaultSparkleUpdateChecker`)
            // are the same ones `AppUpdaterViewModel.live` uses, so the
            // two surfaces produce identical update lists.
            updatesChecker: { await Self.fetchAvailableUpdates(log: log) },
            junkCleaner: { try await SystemJunkDeleter().delete($0) },
            threatRemover: { await remover.remove($0) },
            // Wires identical to `OptimizationViewModel.live` so Smart Scan's
            // Performance tile runs the same maintenance scripts the
            // standalone Optimization screen does.
            maintenanceRunner: { try await MaintenanceScriptRunner().run() },
            // Open every selected update URL via `NSWorkspace.open`. Mirrors
            // `AppUpdaterViewModel.live`'s opener — kept local rather than
            // shared because the two surfaces have no other state to share.
            updateOpener: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            },
            // Per-URL `FileManager.removeItem` loop. Duplicated from
            // `LargeOldFilesViewModel.removeUserFiles` rather than promoting
            // that private static so this slice doesn't touch unrelated
            // code (CLAUDE.md rule). Failures are logged with hash-masked
            // privacy and skipped; the surviving files would stay in the
            // dashboard if Run is re-run.
            largeFileDeleter: { urls in
                await Self.removeClutterFiles(at: urls, log: log)
            }
        )
    }

    /// Discover-and-probe loop for the Applications tile. Mirrors
    /// `AppUpdaterViewModel.checkForUpdates`'s bounded-concurrency window
    /// (≤6 in-flight HTTPS requests) so a heavily-installed machine never
    /// stampedes the iTunes Search API or assorted Sparkle hosts during
    /// Smart Scan. Marked `nonisolated` so the HTTP fan-out runs off the
    /// main actor — without this annotation the static would inherit
    /// `@MainActor` from the class extension and serialize on the UI
    /// thread, freezing every per-app hop on the scan's progress label.
    nonisolated private static func fetchAvailableUpdates(log: Logger) async -> [UpdateInfo] {
        let discovery = DefaultAppDiscovery()
        let appStore = DefaultAppStoreUpdateChecker()
        let sparkle = DefaultSparkleUpdateChecker()
        do {
            let apps = try await discovery.installedApps(includingSystemApps: false)
            let updates = await withTaskGroup(of: UpdateInfo?.self) { group -> [UpdateInfo] in
                var nextIndex = 0
                let maxInFlight = 6
                while nextIndex < apps.count, nextIndex < maxInFlight {
                    let app = apps[nextIndex]
                    group.addTask {
                        await Self.checkUpdate(for: app, appStore: appStore, sparkle: sparkle)
                    }
                    nextIndex += 1
                }
                var results: [UpdateInfo] = []
                while let result = await group.next() {
                    if let info = result { results.append(info) }
                    if nextIndex < apps.count {
                        let app = apps[nextIndex]
                        group.addTask {
                            await Self.checkUpdate(for: app, appStore: appStore, sparkle: sparkle)
                        }
                        nextIndex += 1
                    }
                }
                return results
            }
            return updates.sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        } catch {
            log.error("Smart Scan updates check failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Routes a single installed app to its update channel and returns an
    /// `UpdateInfo` only when the remote version is strictly newer. Every
    /// failure — network, decode, missing feed — is swallowed to `nil` so
    /// one bad app can never blank the whole list. Nonisolated for the
    /// same reason as `fetchAvailableUpdates`.
    nonisolated private static func checkUpdate(
        for app: AppInfo,
        appStore: DefaultAppStoreUpdateChecker,
        sparkle: DefaultSparkleUpdateChecker
    ) async -> UpdateInfo? {
        if app.isAppStore {
            guard let lookup = (try? await appStore.latestVersion(forBundleID: app.bundleID)) ?? nil else {
                return nil
            }
            let installed = app.version ?? "0"
            guard VersionComparator.isNewer(version: lookup.version, than: installed) else { return nil }
            return UpdateInfo(
                appName: app.name,
                bundleID: app.bundleID,
                bundleURL: app.bundleURL,
                installedVersion: installed,
                latestVersion: lookup.version,
                source: .appStore,
                updateURL: lookup.appStoreURL
            )
        } else {
            guard let feedURL = sparkle.feedURL(for: app) else { return nil }
            guard let item = (try? await sparkle.fetchAppcast(feedURL: feedURL)) ?? nil else {
                return nil
            }
            let installed = app.version ?? "0"
            guard VersionComparator.isNewer(version: item.shortVersion, than: installed) else { return nil }
            return UpdateInfo(
                appName: app.name,
                bundleID: app.bundleID,
                bundleURL: app.bundleURL,
                installedVersion: installed,
                latestVersion: item.shortVersion,
                source: .sparkle,
                updateURL: item.downloadURL
            )
        }
    }

    /// Deletes the given user files and returns the set of URLs whose
    /// removal succeeded. Errors are logged with hash-masked privacy so OS
    /// Log redacts paths and error messages outside the user's machine.
    /// Marked `nonisolated` so a multi-gigabyte batch doesn't block the
    /// main actor while `FileManager.removeItem` iterates.
    private nonisolated static func removeClutterFiles(
        at urls: [URL],
        log: Logger
    ) async -> Set<URL> {
        var deleted: Set<URL> = []
        let manager = FileManager.default
        for url in urls {
            do {
                try manager.removeItem(at: url)
                deleted.insert(url)
            } catch {
                log.debug(
                    "Smart Scan clutter delete skipped \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        return deleted
    }
}

// MARK: - ScanCoordinating

extension SmartScanViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.results`/`.cleaning`/`.done`/`.failed` all want the
    /// section's own detail UI, whose internal switch renders the specifics.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning:
            return .working
        case .results, .cleaning, .done, .failed:
            return .results
        }
    }

    func beginScan() {
        Task { await scan() }
    }
}
