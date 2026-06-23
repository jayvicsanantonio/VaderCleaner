// SmartScanViewModel.swift
// State machine behind the Smart Scan feature view — orchestrates the System Junk, Malware, and Optimization sub-modules into one concurrent scan, aggregates their results, and drives a single junk+threats clean pass.

import AppKit
import Foundation
import Observation
import os.log

/// The five tiles the Smart Scan dashboard renders, one per orchestrated
/// sub-module. The enum drives both the rendering loop and the per-tile
/// selection set the user toggles on the dashboard. The case order mirrors
/// the left-to-right reading order on the dashboard so iterating
/// `allCases` lays the tiles out the same way the reference does.
///
/// Raw values are stable string keys (the case names) so the Scanning
/// preferences can persist which modules the user includes in Smart Scan;
/// they must not change once shipped.
enum SmartScanModule: String, Hashable, CaseIterable {
    case systemJunk
    case malware
    case optimization
    case applications
    case myClutter
}

/// The phase the in-flight Smart Scan is currently focused on, derived from
/// which sub-scans have finished. The five sub-scans run concurrently, so this
/// reflects the most foundational work still running: the broad file sweep
/// first, then the malware content scan, then the app-update probe — the same
/// order in which they typically settle. The progress screen uses it to show a
/// phrase set themed to whatever is actually being scanned right now.
enum SmartScanStage: Hashable {
    /// The two file-walk sub-scans (System Junk + My Clutter) are still
    /// enumerating the disk.
    case sweepingFiles
    /// The file walks are done; the malware content scan is still running.
    case scanningThreats
    /// File walks and malware are done; the app-update probe is finishing up.
    case checkingApps
}

/// One aggregated Smart Scan result, holding each sub-module's findings so the
/// results screen can render a card per module. `clamAVAvailable` lets the
/// Malware card hide its remove action when ClamAV is absent (the scan was
/// skipped, so an empty `threats` list there is "unknown", not "clean").
struct SmartScanResult: Equatable {
    let junkResult: ScanResult
    let threats: [MalwareThreat]
    let optimizationItems: [LoginItem]
    /// Duplicate-file groups surfaced by the duplicate sub-scan, fronting the
    /// "My Clutter" tile on the dashboard (matching Smart Care, which finds
    /// duplicate files in Downloads). Empty when the scan found nothing — or, in
    /// live wiring, when the underlying scanner failed (failures are swallowed to
    /// `[]` so one bad probe never sinks an otherwise-useful Smart Scan).
    let duplicateGroups: [DuplicateGroup]
    /// Per-app updates surfaced by the App Updater sub-check, fronting the
    /// "Applications" tile. Same partial-degradation contract as `threats`
    /// and `duplicateGroups` — a network failure yields `[]`, not `.failed`.
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
/// wiring lives in `SmartScanViewModel.live(exclusions:settings:)`.
@MainActor
@Observable
final class SmartScanViewModel {

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
    /// Smart Scan, mirroring `SystemJunkViewModel.Scanner`. The
    /// `@Sendable (Int) -> Void` parameter receives the running walked-item
    /// count so Smart Scan can show its sub-scans advancing.
    typealias JunkScanner = (@escaping @Sendable (Int) -> Void) async throws -> ScanResult
    /// Whether ClamAV is installed. When `false` the malware scan is skipped
    /// entirely and the Malware card hides its action.
    typealias MalwareInstalled = () -> Bool
    /// Malware scan source. Non-throwing and best-effort: a broken ClamAV
    /// install must not fail an otherwise-useful Smart Scan, so the live
    /// wiring logs and yields `[]` rather than propagating. The
    /// `@Sendable (Int) -> Void` parameter receives the running files-checked
    /// count so Smart Scan can show the malware sub-scan advancing after the
    /// file-walk tally plateaus.
    typealias MalwareScanner = (@escaping @Sendable (Int) -> Void) async -> [MalwareThreat]
    /// Login-item loader, mirroring `OptimizationViewModel.LoadLoginItems`.
    typealias LoginItemsLoader = () async -> [LoginItem]
    /// Duplicate-file scan source, fronting the My Clutter tile. Non-throwing
    /// and best-effort: a partly-blocked filesystem walk must not fail the whole
    /// Smart Scan, so the live wiring catches and yields `[]` (same shape as the
    /// malware sub-scan). The `@Sendable (Int) -> Void` parameter receives the
    /// running walked-item count so Smart Scan can show its sub-scans advancing.
    typealias ClutterScanner = (@escaping @Sendable (Int) -> Void) async -> [DuplicateGroup]
    /// App-update check source, fronting the Applications tile. Non-throwing
    /// and best-effort for the same reason as `ClutterScanner` — a
    /// network blip can't sink an otherwise-useful Smart Scan. The
    /// `@Sendable (Int, Int) -> Void` parameter receives the running
    /// `(appsChecked, appsTotal)` so Smart Scan can show determinate progress
    /// for the network-bound probe.
    typealias UpdatesChecker = (@escaping @Sendable (_ checked: Int, _ total: Int) -> Void) async -> [UpdateInfo]
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
    /// were actually removed. Mirrors `MyClutterViewModel`'s deleter:
    /// partial-success is the norm (a single locked file must not abort the
    /// batch), so the return is the success set, not a failure set.
    typealias LargeFileDeleter = ([URL]) async -> Set<URL>

    private(set) var phase: Phase = .idle

    /// Called with the aggregated result the moment a Smart Scan completes, so a
    /// host (ContentView) can seed the same-scope standalone sections (System
    /// Junk, Large & Old Files, Malware) and spare the user a re-scan. Settable
    /// post-init so wiring it adds no constructor churn; `nil` by default (tests
    /// and previews don't seed).
    var onScanCompleted: ((SmartScanResult) -> Void)?

    /// Combined count of filesystem items walked by the two file-walk sub-scans
    /// (System Junk + My Clutter) during the in-flight Smart Scan. Reset to 0
    /// at scan start and surfaced as "Scanned N items…" beneath the stage label
    /// so the user sees the composite scan advancing.
    private(set) var scannedItemCount: Int = 0

    /// Running count of files the malware sub-scan has checked during the
    /// in-flight Smart Scan. The file-walk tally (`scannedItemCount`) plateaus
    /// the moment the two walks finish enumerating the disk, but the malware
    /// content scan keeps running; surfacing its own count keeps the progress
    /// readout honest about what is still happening. Reset to 0 at scan start.
    private(set) var malwareFilesScanned: Int = 0

    /// Determinate progress for the app-update sub-check: `appsChecked` of
    /// `appsTotal` apps probed. The probe knows the total up front, so this
    /// reads as bounded progress for the network-bound check that otherwise
    /// outlasts the file walks with no visible movement. Both reset to 0 at
    /// scan start.
    private(set) var appsChecked: Int = 0
    private(set) var appsTotal: Int = 0

    /// Per-sub-scan completion flags, set as each sub-scan returns and reset at
    /// scan start. `currentStage` reads them to decide which phrase set the
    /// progress screen shows. Observed (not `@ObservationIgnored`) so the view
    /// re-evaluates `currentStage` when a stage boundary is crossed.
    private(set) var junkWalkComplete = false
    private(set) var clutterWalkComplete = false
    private(set) var malwareScanComplete = false

    /// Both file walks have finished enumerating the disk.
    private var fileWalksComplete: Bool { junkWalkComplete && clutterWalkComplete }

    /// Which sub-scan the in-flight scan is currently focused on, by precedence
    /// of the most foundational work still running. Only meaningful during
    /// `.scanning`; the progress screen reads it to theme its rotating phrases.
    var currentStage: SmartScanStage {
        if !fileWalksComplete { return .sweepingFiles }
        if !malwareScanComplete { return .scanningThreats }
        return .checkingApps
    }

    /// One status line composing every active sub-scan signal — the file-walk
    /// item count, the malware files-checked count, and the app-update
    /// "N of M" — so the user always sees what the in-flight scan is doing,
    /// even after the headline item count plateaus. Parts only appear once
    /// their sub-scan has reported, so early ticks read as a plain item count.
    var scanProgressDetail: String {
        var parts = [ScanProgressFormatting.itemsScanned(scannedItemCount)]
        if malwareFilesScanned > 0 {
            parts.append(ScanProgressFormatting.threatsScanned(malwareFilesScanned))
        }
        if appsTotal > 0 {
            parts.append(ScanProgressFormatting.appsChecked(appsChecked, of: appsTotal))
        }
        return parts.joined(separator: " · ")
    }

    /// Which tiles on the dashboard are checked. Empty at `.idle`; seeded on
    /// the `.scanning → .results` transition to "every module that has
    /// actionable work" (matching the reference's default-all-on behavior),
    /// and cleared again on `reset()`. The Run pass iterates this set so a
    /// deselected tile is skipped entirely.
    private(set) var tileSelection: Set<SmartScanModule> = []

    /// Per-file gate inside the System Junk tile's Cleanup Manager, keyed by
    /// `ScannedFile.url`. This is the source of truth for which junk files Run
    /// removes — seeded to every scanned file (default-all-on) so the manager
    /// opens fully checked. Category-level state is derived from it (see
    /// `junkCategorySelection`).
    private(set) var junkFileSelection: Set<URL> = []

    /// Per-category view of `junkFileSelection`: a category counts as selected
    /// when every one of its files is selected. Kept as a derived facade so the
    /// dashboard's caption decisions and the older per-category call sites keep
    /// working while per-file selection is the real model.
    var junkCategorySelection: Set<ScanCategory> {
        guard case .results(let result) = phase else { return [] }
        return Set(result.junkResult.itemsByCategory.compactMap { category, files in
            files.allSatisfy { junkFileSelection.contains($0.url) } ? category : nil
        })
    }

    /// Per-threat gate inside the Malware tile's Review screen, keyed by
    /// `MalwareThreat.filePath`. Seeded to every detected threat. Run filters
    /// the threat list down to this set before handing it to the remover.
    private(set) var threatSelection: Set<URL> = []

    /// Per-update gate inside the Applications tile's Review screen, keyed by
    /// `UpdateInfo.bundleID`. Seeded to every available update; Run hands the
    /// selected updates to the opener one by one.
    private(set) var updateSelection: Set<String> = []

    /// Per-copy gate inside the My Clutter tile's Review screen, keyed by
    /// `ScannedFile.url`. Seeded to every **redundant copy** (every duplicate
    /// except the kept original) — deleting a duplicate always leaves one copy
    /// behind, so default-on is safe and matches Smart Care. Kept originals are
    /// never added here, so Run can never delete the last copy.
    private(set) var largeFileSelection: Set<URL> = []

    /// Per-source walked counts for the two concurrent file-walk sub-scans.
    /// `scannedItemCount` is their sum; tracking them separately lets each
    /// scanner's monotonic count update the combined total independently.
    @ObservationIgnored private var junkWalkCount = 0
    @ObservationIgnored private var clutterWalkCount = 0

    /// Incremented at the start of every scan so a progress tick that hops back
    /// to the main actor after a newer scan began is dropped.
    @ObservationIgnored private var scanGeneration = 0

    @ObservationIgnored private let junkScanner: JunkScanner
    @ObservationIgnored private let malwareInstalled: MalwareInstalled
    @ObservationIgnored private let malwareScanner: MalwareScanner
    @ObservationIgnored private let loginItemsLoader: LoginItemsLoader
    @ObservationIgnored private let duplicatesScanner: ClutterScanner
    @ObservationIgnored private let updatesChecker: UpdatesChecker
    @ObservationIgnored private let junkCleaner: JunkCleaner
    @ObservationIgnored private let threatRemover: ThreatRemover
    @ObservationIgnored private let maintenanceRunner: MaintenanceRunner
    /// Flushes the system DNS cache via the privileged helper. Part of the
    /// Performance/Optimization module alongside the maintenance scripts,
    /// matching Smart Care (which runs maintenance scripts *and* Flush DNS).
    /// Needs no `periodic`, so it runs even on macOS 26 where the scripts are
    /// gone — which is why Optimization always has Run work.
    @ObservationIgnored private let dnsFlusher: MaintenanceRunner
    @ObservationIgnored private let updateOpener: UpdateOpener
    @ObservationIgnored private let largeFileDeleter: LargeFileDeleter
    /// Whether `/usr/sbin/periodic` exists — false on macOS 26+, where Apple
    /// removed it. When false the Optimization tile's maintenance-scripts action
    /// has nothing to run, so it is not auto-selected and Run skips it.
    @ObservationIgnored private let maintenanceScriptsAvailable: Bool

    /// "Customize Smart Care" gate: the set of modules the user includes in
    /// Smart Scan. Read once per `scan()` (snapshot, like the exclusions store)
    /// so a preference change takes effect on the next scan. Defaults to all
    /// modules so unconfigured installs scan everything.
    @ObservationIgnored private let enabledModules: () -> Set<SmartScanModule>
    /// Companion gate for the Cleanup (System Junk) sub-tree: the categories the
    /// user includes. Only consulted when `.systemJunk` is enabled. Defaults to
    /// every System Junk category.
    @ObservationIgnored private let enabledJunkCategories: () -> Set<ScanCategory>

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "SmartScanViewModel")

    init(
        junkScanner: @escaping JunkScanner,
        malwareInstalled: @escaping MalwareInstalled,
        malwareScanner: @escaping MalwareScanner,
        loginItemsLoader: @escaping LoginItemsLoader,
        duplicatesScanner: @escaping ClutterScanner,
        updatesChecker: @escaping UpdatesChecker,
        junkCleaner: @escaping JunkCleaner,
        threatRemover: @escaping ThreatRemover,
        maintenanceRunner: @escaping MaintenanceRunner,
        dnsFlusher: @escaping MaintenanceRunner = { "" },
        updateOpener: @escaping UpdateOpener,
        largeFileDeleter: @escaping LargeFileDeleter,
        maintenanceScriptsAvailable: Bool = true,
        enabledModules: @escaping () -> Set<SmartScanModule> = { Set(SmartScanModule.allCases) },
        enabledJunkCategories: @escaping () -> Set<ScanCategory> = { Set(SmartScanSettingsStore.junkCategories) }
    ) {
        self.junkScanner = junkScanner
        self.malwareInstalled = malwareInstalled
        self.malwareScanner = malwareScanner
        self.loginItemsLoader = loginItemsLoader
        self.duplicatesScanner = duplicatesScanner
        self.updatesChecker = updatesChecker
        self.junkCleaner = junkCleaner
        self.threatRemover = threatRemover
        self.maintenanceRunner = maintenanceRunner
        self.dnsFlusher = dnsFlusher
        self.updateOpener = updateOpener
        self.largeFileDeleter = largeFileDeleter
        self.maintenanceScriptsAvailable = maintenanceScriptsAvailable
        self.enabledModules = enabledModules
        self.enabledJunkCategories = enabledJunkCategories
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
            localized: "Scanning cleanup, protection, performance, applications, and duplicates…",
            comment: "Progress label shown while the Smart Scan runs all five sub-scans — uses the user-facing tile names from the results dashboard."
        ))

        scanGeneration &+= 1
        let generation = scanGeneration
        scannedItemCount = 0
        junkWalkCount = 0
        clutterWalkCount = 0
        malwareFilesScanned = 0
        appsChecked = 0
        appsTotal = 0
        junkWalkComplete = false
        clutterWalkComplete = false
        malwareScanComplete = false

        // The two file-walk sub-scans run concurrently and each report their own
        // monotonic walked count; sum them into one "Scanned N items…" tally.
        // The scanners run off the main actor, so hop back before touching the
        // observable count, and drop ticks from a superseded scan.
        // These hops are unstructured, so they can land out of order; each
        // sub-scan's walked count is monotonic, so ignore any tick that would
        // move its counter backwards rather than let the combined total jitter.
        let onJunkProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in
                // Drop the tick if a newer scan started, if it would move the
                // count backwards, or if the scan has already left `.scanning`
                // (a tick enqueued just before the terminal phase must not
                // re-trigger observation once the dashboard is showing).
                guard let self,
                      self.scanGeneration == generation,
                      case .scanning = self.phase,
                      count > self.junkWalkCount else { return }
                self.junkWalkCount = count
                self.scannedItemCount = self.junkWalkCount + self.clutterWalkCount
            }
        }
        let onClutterProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in
                guard let self,
                      self.scanGeneration == generation,
                      case .scanning = self.phase,
                      count > self.clutterWalkCount else { return }
                self.clutterWalkCount = count
                self.scannedItemCount = self.junkWalkCount + self.clutterWalkCount
            }
        }
        // The two silent sub-scans report their own progress so the readout
        // keeps moving after the file walks plateau. Same guard shape as the
        // walk ticks: drop ticks from a superseded scan, from a terminal
        // phase, or that would move a monotonic counter backwards.
        let onMalwareProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in
                guard let self,
                      self.scanGeneration == generation,
                      case .scanning = self.phase,
                      count > self.malwareFilesScanned else { return }
                self.malwareFilesScanned = count
            }
        }
        let onUpdatesProgress: @Sendable (Int, Int) -> Void = { [weak self] checked, total in
            Task { @MainActor in
                guard let self,
                      self.scanGeneration == generation,
                      case .scanning = self.phase,
                      checked >= self.appsChecked else { return }
                self.appsChecked = checked
                self.appsTotal = total
            }
        }

        let clamAVAvailable = malwareInstalled()

        // "Customize Smart Care" gate: snapshot the user's module/category
        // choices once up front (mirroring the exclusions snapshot) so a
        // disabled module's sub-scan is skipped entirely and a disabled System
        // Junk category is filtered out of the results below.
        let mods = enabledModules()
        let cats = enabledJunkCategories()

        async let junk = scanJunkIfEnabled(mods.contains(.systemJunk), onProgress: onJunkProgress)
        async let threats = scanForThreatsIfPossible(
            clamAVAvailable: clamAVAvailable && mods.contains(.malware),
            onProgress: onMalwareProgress
        )
        async let login = mods.contains(.optimization) ? loginItemsLoader() : []
        async let large = mods.contains(.myClutter) ? duplicatesScanner(onClutterProgress) : []
        async let updates = mods.contains(.applications) ? updatesChecker(onUpdatesProgress) : []

        do {
            // Await the two file walks first so their completion flags flip the
            // moment the disk enumeration finishes — the malware content scan
            // and app-update probe routinely outlast them, and the stage label
            // must follow the work that is *actually* still running, not the
            // textual order of these awaits. (`async let` already started all
            // five concurrently, so collecting them in a different order is
            // free.)
            // Filter the System Junk findings down to the categories the user
            // kept enabled in the Cleanup sub-tree. Done here (rather than in the
            // scanner) so the scanner stays category-agnostic and the same walk
            // serves every caller.
            let junkResult = Self.filteringJunkCategories(try await junk, to: cats)
            junkWalkComplete = true
            let duplicates = await large
            clutterWalkComplete = true
            let loginItems = await login
            let foundThreats = await threats
            malwareScanComplete = true
            let foundUpdates = await updates

            let result = SmartScanResult(
                junkResult: junkResult,
                threats: foundThreats,
                optimizationItems: loginItems,
                duplicateGroups: duplicates,
                availableUpdates: foundUpdates,
                clamAVAvailable: clamAVAvailable
            )
            // Intersect with the enabled modules so a module the user excluded
            // never comes back auto-selected — notably Optimization, which
            // otherwise always auto-selects (its DNS flush always has work).
            tileSelection = Self.defaultTileSelection(for: result).intersection(mods)
            junkFileSelection = Set(result.junkResult.items.map(\.url))
            threatSelection = Set(foundThreats.map(\.filePath))
            updateSelection = Set(foundUpdates.map(\.bundleID))
            // Seed every redundant copy (every duplicate except the kept
            // original) so Run removes the extras by default — a copy is always
            // retained, so this is safe. The scanner already orders groups by
            // reclaimable bytes, so no re-sort is needed for the Review list.
            largeFileSelection = Set(duplicates.flatMap { $0.redundantCopies.map(\.url) })
            phase = .results(result)
            // Hand the aggregated result to whoever wired seeding (ContentView)
            // so the same-scope standalone sections can show these results
            // without making the user scan them again.
            onScanCompleted?(result)
        } catch {
            log.error("Smart Scan failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Runs the System Junk scan only when its module is enabled. Factored out
    /// of `scan()` so the throwing `async let` site stays readable — a ternary
    /// around a `try await` call reads poorly. Disabled yields an empty result,
    /// which still flips `junkWalkComplete` cleanly when awaited.
    private func scanJunkIfEnabled(
        _ enabled: Bool,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> ScanResult {
        guard enabled else { return ScanResult(items: []) }
        return try await junkScanner(onProgress)
    }

    /// Returns a `ScanResult` containing only the files whose category the user
    /// kept enabled in the Cleanup sub-tree. A no-op (returns the input) when
    /// every category is enabled, so the common path allocates nothing extra.
    private static func filteringJunkCategories(
        _ result: ScanResult,
        to categories: Set<ScanCategory>
    ) -> ScanResult {
        guard categories.count != SmartScanSettingsStore.junkCategories.count else {
            return result
        }
        return ScanResult(items: result.items.filter { categories.contains($0.category) })
    }

    /// Runs the malware scan only when ClamAV is present. Factored out of
    /// `scan()` so the `async let` site stays readable and the gating logic
    /// isn't buried in a conditional async closure.
    private func scanForThreatsIfPossible(
        clamAVAvailable: Bool,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> [MalwareThreat] {
        guard clamAVAvailable else { return [] }
        return await malwareScanner(onProgress)
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
            // Per-file selection: clean exactly the files the user left checked
            // in the Cleanup Manager. Capture the selection once so the filter
            // isn't re-evaluating the observable set per element.
            let selected = junkFileSelection
            let selectedJunk = result.junkResult.items.filter { selected.contains($0.url) }
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

        // Performance runs two tasks, matching Smart Care: the periodic
        // maintenance scripts and a DNS-cache flush. Each is in its own catch so
        // one failing doesn't sink the other, and their result lines are folded
        // into one `maintenanceOutput`. `maintenanceScriptsAvailable` still gates
        // the scripts (periodic was removed in macOS 26, so running it would only
        // surface "The file 'periodic' doesn't exist."); the DNS flush needs no
        // periodic, so it always runs when the tile is selected.
        if tileSelection.contains(.optimization) {
            var lines: [String] = []
            if maintenanceScriptsAvailable {
                do {
                    lines.append(try await maintenanceRunner())
                } catch {
                    log.error("Smart Scan maintenance failed: \(String(describing: error), privacy: .public)")
                    failedModules.insert(.optimization)
                }
            }
            do {
                let dnsLine = try await dnsFlusher()
                if !dnsLine.isEmpty { lines.append(dnsLine) }
            } catch {
                log.error("Smart Scan DNS flush failed: \(String(describing: error), privacy: .public)")
                failedModules.insert(.optimization)
            }
            if !lines.isEmpty { maintenanceOutput = lines.joined(separator: "\n") }
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
            // Walk every duplicate copy the scan recorded to total bytes the
            // deleter actually freed, since the deleter only reports URLs.
            clutterBytesRemoved = result.duplicateGroups
                .flatMap { $0.files }
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

    /// Toggling a category is a bulk operation over its files: if every file is
    /// currently selected, clear them all; otherwise select them all. Done as a
    /// single write to `junkFileSelection` so SwiftUI sees one publish.
    func toggleJunkCategory(_ category: ScanCategory) {
        guard case .results(let result) = phase,
              let files = result.junkResult.itemsByCategory[category] else { return }
        let urls = files.map(\.url)
        if urls.allSatisfy({ junkFileSelection.contains($0) }) {
            junkFileSelection.subtract(urls)
        } else {
            junkFileSelection.formUnion(urls)
        }
    }

    /// Whether an individual junk file is checked for removal in the Cleanup
    /// Manager's file pane.
    func isJunkFileSelected(_ file: ScannedFile) -> Bool {
        junkFileSelection.contains(file.url)
    }

    /// Flips a single junk file's checked state.
    func toggleJunkFile(_ file: ScannedFile) {
        if junkFileSelection.contains(file.url) {
            junkFileSelection.remove(file.url)
        } else {
            junkFileSelection.insert(file.url)
        }
    }

    /// Check or uncheck every file in a category in one write — backs the
    /// Cleanup Manager's "Select: All / None" menu. A single set mutation so
    /// SwiftUI sees one publish rather than one per file.
    func setJunkCategory(_ category: ScanCategory, selected: Bool) {
        guard case .results(let result) = phase,
              let files = result.junkResult.itemsByCategory[category] else { return }
        let urls = files.map(\.url)
        if selected {
            junkFileSelection.formUnion(urls)
        } else {
            junkFileSelection.subtract(urls)
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

    /// Check or uncheck every detected threat in one write — backs the
    /// Protection Manager's "Select: All / None" menu.
    func setAllThreats(selected: Bool) {
        guard case .results(let result) = phase else { return }
        threatSelection = selected ? Set(result.threats.map(\.filePath)) : []
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

    /// Check or uncheck every available update in one write — backs the
    /// Applications Manager's "Select: All / None" menu.
    func setAllUpdates(selected: Bool) {
        guard case .results(let result) = phase else { return }
        updateSelection = selected ? Set(result.availableUpdates.map(\.bundleID)) : []
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

    /// Select every redundant duplicate copy for removal in one write to
    /// `largeFileSelection` (kept originals are never included, so a copy always
    /// survives). A single set assignment so SwiftUI observes one publish instead
    /// of N (one per `toggleLargeFile` call), which on large scans would
    /// otherwise stall the UI behind the cascade of refreshes.
    func selectAllLargeFiles() {
        guard case .results(let result) = phase else { return }
        largeFileSelection = Set(result.duplicateGroups.flatMap { $0.redundantCopies.map(\.url) })
    }

    /// Opt every file back out — single-write counterpart to
    /// `selectAllLargeFiles()`.
    func clearLargeFileSelection() {
        largeFileSelection = []
    }

    /// Check or uncheck a specific set of clutter files in one write — backs
    /// the Clutter Manager's per-category "Select: All / None" menu.
    func setLargeFiles(_ urls: [URL], selected: Bool) {
        if selected {
            largeFileSelection.formUnion(urls)
        } else {
            largeFileSelection.subtract(urls)
        }
    }

    // MARK: - Executable work surface

    /// Whether the given module would actually produce work if Run were
    /// pressed right now. The tile must be selected, *and* its sub-selection
    /// must filter down to at least one item. Optimization always produces work
    /// because its DNS-cache flush needs no `periodic` (the maintenance scripts
    /// are an extra task that's skipped where `periodic` is gone in macOS 26).
    ///
    /// Read by both the dashboard's per-tile caption decisions and the
    /// floating Run disc's visibility gate, so the two surfaces share one
    /// source of truth.
    func willExecute(_ module: SmartScanModule) -> Bool {
        guard case .results(let result) = phase else { return false }
        guard isModuleSelected(module) else { return false }
        switch module {
        case .systemJunk:
            // At least one scanned junk file is still checked. `contains(where:)`
            // short-circuits on the first hit, so this stays cheap even under
            // heavy junk scans where `hasExecutableWork` calls it every refresh.
            return result.junkResult.items.contains { junkFileSelection.contains($0.url) }
        case .malware:
            return result.threats.contains {
                threatSelection.contains($0.filePath)
            }
        case .optimization:
            // The DNS-cache flush always has work (no `periodic` dependency),
            // so Optimization is actionable on every macOS — even where the
            // maintenance scripts are gone.
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

    /// Whether the system maintenance scripts can run on this macOS — false on
    /// macOS 26+, where Apple removed `periodic`. Exposed so the Performance
    /// Review can phrase its explainer accurately.
    var maintenanceScriptsSupported: Bool { maintenanceScriptsAvailable }

    /// Default tile-selection seed for a freshly-landed `.results` payload.
    /// A module starts checked iff it has actionable work for Run. Optimization
    /// always starts on because its DNS-cache flush always has work (the
    /// maintenance scripts are an extra, gated at Run time). The user can still
    /// deselect any tile on the dashboard.
    private static func defaultTileSelection(
        for result: SmartScanResult
    ) -> Set<SmartScanModule> {
        var selection: Set<SmartScanModule> = [.optimization]
        if result.totalJunkBytes > 0 { selection.insert(.systemJunk) }
        if !result.threats.isEmpty { selection.insert(.malware) }
        if !result.availableUpdates.isEmpty { selection.insert(.applications) }
        if !result.duplicateGroups.isEmpty { selection.insert(.myClutter) }
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
        junkFileSelection = []
        threatSelection = []
        updateSelection = []
        largeFileSelection = []
        scannedItemCount = 0
        malwareFilesScanned = 0
        appsChecked = 0
        appsTotal = 0
        junkWalkComplete = false
        clutterWalkComplete = false
        malwareScanComplete = false
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
    /// `SystemJunkViewModel.live`. The Scanning preferences (`settings`) are
    /// captured the same way, so a module or category the user toggles in
    /// Settings → Scanning takes effect on the next Smart Scan.
    @MainActor
    static func live(
        exclusions: ExclusionsStore,
        settings: SmartScanSettingsStore
    ) -> SmartScanViewModel {
        let detector = ClamAVDetector()
        let scanner = ClamAVScanner(detector: detector)
        let remover = MalwareThreatRemover()
        let loginManager = LoginItemsManager.live()
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SmartScanViewModel.live")

        return SmartScanViewModel(
            junkScanner: { [weak exclusions] onProgress in
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                return try await SystemJunkScanner.live().scan(excluding: excluded, onProgress: onProgress)
            },
            malwareInstalled: { detector.isInstalled() },
            // Best-effort: a missing signature database or a broken clamscan
            // binary must not sink an otherwise-useful Smart Scan. We log the
            // failure (rather than swallow it silently) so an unexpectedly
            // empty Malware card is debuggable, then degrade to "no threats".
            //
            // Scope matches the standalone Malware screen's default Quick Scan
            // — the high-risk home subdirectories (Downloads/Desktop/Documents)
            // rather than all of $HOME. A full-home clamscan reads every file's
            // contents and dominated Smart Scan's wall-clock time, since the
            // dashboard waits for every sub-scan before it can render.
            malwareScanner: { onProgress in
                let quickPaths = MalwareViewModel.defaultQuickScanPaths()
                // clamscan prints one line per file it checks, so counting the
                // streamed lines is a faithful "files checked" tally — the same
                // derivation the standalone Malware screen uses. The count is
                // maintained here (off the main actor) and forwarded as a
                // running total to the view model's monotonic progress sink.
                let counter = ScanLineCounter()
                do {
                    return try await scanner.scan(paths: quickPaths, progress: { _ in
                        onProgress(counter.increment())
                    })
                } catch {
                    log.error("Smart Scan malware sub-scan failed, treating as no threats: \(String(describing: error), privacy: .public)")
                    return []
                }
            },
            loginItemsLoader: { loginManager.items() },
            // Duplicate files in Downloads, fronting the My Clutter tile to match
            // Smart Care. A partly-blocked filesystem walk must not sink the
            // whole Smart Scan, so failures are logged and degraded to an empty
            // list (same partial-degradation contract as the malware scanner).
            duplicatesScanner: { [weak exclusions] onProgress in
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                do {
                    return try await DuplicateScanner().scan(excluding: excluded, onProgress: onProgress)
                } catch {
                    log.error("Smart Scan duplicates sub-scan failed, treating as no files: \(String(describing: error), privacy: .public)")
                    return []
                }
            },
            // App Updater wiring: discover installed apps, then fan out
            // per-app version probes against the App Store and Sparkle
            // channels. The underlying collaborators (`DefaultAppDiscovery`,
            // `UpdateProbe.live()`) are the same ones
            // `AppUpdaterViewModel.live` uses, so the two surfaces produce
            // identical update lists.
            updatesChecker: { onProgress in await Self.fetchAvailableUpdates(log: log, onProgress: onProgress) },
            junkCleaner: { try await SystemJunkDeleter().delete($0) },
            threatRemover: { await remover.remove($0) },
            // Wires identical to `OptimizationViewModel.live` so Smart Scan's
            // Performance tile runs the same maintenance scripts the
            // standalone Optimization screen does.
            maintenanceRunner: { try await MaintenanceScriptRunner().run() },
            // Flush the DNS cache through the same privileged helper task the
            // standalone Optimization screen uses, matching Smart Care's
            // Performance module (maintenance scripts + Flush DNS).
            dnsFlusher: { try await DNSCacheFlusher().run() },
            // Open every selected update URL via `NSWorkspace.open`. Mirrors
            // `AppUpdaterViewModel.live`'s opener — kept local rather than
            // shared because the two surfaces have no other state to share.
            updateOpener: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            },
            // A standalone per-URL `FileManager.removeItem` loop, kept local so
            // this slice doesn't touch unrelated code (CLAUDE.md rule). Failures
            // are logged with hash-masked privacy and skipped; the surviving
            // files would stay in the dashboard if Run is re-run.
            largeFileDeleter: { urls in
                await Self.removeClutterFiles(at: urls, log: log)
            },
            // `periodic` was removed in macOS 26; when it's absent the
            // Performance tile's maintenance action is skipped rather than
            // erroring with "The file 'periodic' doesn't exist."
            maintenanceScriptsAvailable: FileManager.default.fileExists(atPath: "/usr/sbin/periodic"),
            // Snapshot the "Customize Smart Care" choices per scan so a toggle in
            // Settings → Scanning takes effect on the next run, mirroring the
            // exclusions snapshot above.
            enabledModules: { [weak settings] in
                settings?.enabledModules ?? Set(SmartScanModule.allCases)
            },
            enabledJunkCategories: { [weak settings] in
                settings?.enabledJunkCategories ?? Set(SmartScanSettingsStore.junkCategories)
            }
        )
    }

    /// Discover-and-probe loop for the Applications tile. Delegates the
    /// bounded-concurrency fan-out (≤6 in-flight HTTPS requests) to
    /// `UpdateProbe` so a heavily-installed machine never stampedes the
    /// iTunes Search API or assorted Sparkle hosts during Smart Scan.
    /// Marked `nonisolated` so the HTTP fan-out runs off the main actor —
    /// without this annotation the static would inherit `@MainActor` from
    /// the class extension and serialize on the UI thread, freezing every
    /// per-app hop on the scan's progress label.
    nonisolated private static func fetchAvailableUpdates(
        log: Logger,
        onProgress: @escaping @Sendable (_ checked: Int, _ total: Int) -> Void
    ) async -> [UpdateInfo] {
        let discovery = DefaultAppDiscovery()
        do {
            let apps = try await discovery.installedApps(includingSystemApps: false)
            return await UpdateProbe.live().availableUpdates(for: apps, onProgress: onProgress)
        } catch {
            log.error("Smart Scan updates check failed: \(String(describing: error), privacy: .public)")
            return []
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

/// Thread-safe monotonic counter for the malware sub-scan's line stream.
/// `ClamAVScanner` invokes its progress closure from a single background read
/// loop, but the closure is `@escaping` and may outlive the call, so the
/// counter is guarded the same way as `ClamAVScanner`'s own `ThreatCollector`.
private final class ScanLineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Bumps the count and returns the new running total.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
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
