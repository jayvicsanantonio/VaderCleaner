// SmartScanViewModel.swift
// Smart Scan's view model: drives the care-plan state machine — the concurrent checklist scan, the results feed's inclusion and per-finding selections, and the one-tap Run pass that produces a receipt.

import AppKit
import Foundation
import Observation
import os

/// The view model behind the Smart Scan section. Owns the phase machine
/// (`idle → scanning → results → running → done/failed`), consumes
/// `CareScanEngine` events into the live checklist, seeds the safety-tiered
/// selections when results land, and executes the Run pass finding by
/// finding so one failure never sinks the rest.
///
/// Collaborators are injected as closures with a `live()` production factory,
/// matching every other section's view model, so the whole machine is
/// testable against fakes.
@MainActor
@Observable
final class SmartScanViewModel {

    enum Phase: Equatable {
        case idle
        case scanning
        case results(CarePlan)
        case running
        case done(receipt: CareReceipt)
        case failed(message: String)
    }

    /// Live status of one scan unit while `.scanning`, driven by engine
    /// events. Skips and failures arrive as `finished` with their outcome so
    /// the checklist can grey or amber the row honestly.
    enum UnitStatus: Equatable {
        case pending
        case running(itemsScanned: Int)
        case finished(CareUnitOutcome)
    }

    /// One checklist row's derived state — the per-domain rollup of its
    /// units' statuses, with a plain-language result line once every unit
    /// in the domain has landed.
    enum DomainStatus: Equatable {
        case pending
        case running(itemsScanned: Int)
        case finished(line: String)
        case skipped
        case failed
    }

    /// One row of the run-confirmation sheet: the plain-language description of
    /// what a finding's action will do, and whether it is the irreversible
    /// (permanent junk delete) step so the sheet can mark it.
    struct RunActionLine: Identifiable, Equatable {
        let kind: CareFinding.Kind
        let text: String
        let isPermanent: Bool
        var id: CareFinding.Kind { kind }
    }

    // MARK: - Collaborator shapes

    typealias ScanEngine = @Sendable (
        CareScanEngine.Configuration,
        @escaping @Sendable (CareScanEngine.Event) -> Void
    ) async -> CarePlan
    typealias JunkCleaner = ([ScannedFile]) async throws -> Int64
    typealias ThreatRemover = ([MalwareThreat]) async -> [MalwareThreat]
    typealias UpdateOpener = (URL) async -> Void
    /// Moves the given files to the Trash and returns the URLs that made it —
    /// the same restorable contract `ApplicationsViewModel`/`MyClutterViewModel`
    /// use, because user files must survive a change of heart.
    typealias RecycleFiles = @Sendable ([URL]) async -> Set<URL>
    /// Runs one maintenance task by its `MaintenanceTask.Kind` raw value.
    typealias MaintenanceTaskRunner = (String) async throws -> Void
    typealias PrivacyRemover = ([PrivacyRemovalRequest]) async throws -> Void

    // MARK: - Observable state

    private(set) var phase: Phase = .idle

    /// Called with the aggregated plan the moment a Smart Scan completes, so
    /// ContentView can seed the same-scope standalone sections and spare the
    /// user a re-scan. `nil` by default (tests and previews don't seed).
    var onScanCompleted: ((CarePlan) -> Void)?

    /// Persistent, prebuilt model behind the junk Review — the same store the
    /// standalone Cleanup Manager uses. Warmed as soon as a scan lands
    /// results so the Review's panes paint instantly. Owned here — not as
    /// view `@State` — so freeing its per-file index (millions of entries on
    /// a large scan) never happens on the main thread mid-transition.
    @ObservationIgnored let junkManagerStore = CleanupManagerStore()


    /// Per-unit live status for the scanning checklist.
    private(set) var unitStatuses: [CareScanUnit: UnitStatus] = [:]

    /// Findings streamed in by finished units during `.scanning`, so the
    /// checklist can show each domain's result line the moment it lands —
    /// before the whole scan completes.
    private(set) var liveFindings: [CareFinding.Kind: CareFinding] = [:]

    /// Combined count of items examined across every in-flight unit, for the
    /// menu bar's "Scanned N items…" line and the checklist header.
    private(set) var scannedItemCount = 0

    /// Which results cards are included in the Run pass. Seeded to the
    /// pre-approved findings; opt-in cards join automatically when their
    /// review selection becomes non-empty and leave when it clears.
    private(set) var includedFindings: Set<CareFinding.Kind> = []

    /// Whether a Review screen is open over the results feed — mirrored here
    /// so the floating Run disc (hosted in a separate panel) can hide.
    private(set) var isReviewing = false

    /// Whether the run-confirmation sheet is up. Set by `requestRun()` only
    /// when the pending run includes a permanent delete (junk); the sheet
    /// confirms that one irreversible step before anything happens. The Run
    /// disc hides while it is showing so it can't be tapped behind the sheet.
    private(set) var isConfirmingRun = false

    // Per-finding selections. Pre-approved kinds seed full; opt-in kinds
    // (real user data) seed empty — removal is always an explicit choice.
    private(set) var junkFileSelection: Set<URL> = [] {
        didSet { junkSelectionRevision &+= 1 }
    }

    /// Bumped on every change to `junkFileSelection`, so a consumer can tell
    /// whether a cached answer about the selection is still valid. Driven by
    /// `didSet` rather than by each mutating method, so a future write site
    /// can't forget to bump it and leave a stale checkbox on screen. Backs the
    /// Cleanup Manager's per-row aggregate cache (see `CleanupManagerStore`).
    private(set) var junkSelectionRevision = 0
    private(set) var selectedJunkBytes: Int64 = 0
    private(set) var selectedJunkBytesByCategory: [ScanCategory: Int64] = [:]
    private(set) var selectedJunkCountByCategory: [ScanCategory: Int] = [:]
    private(set) var threatSelection: Set<URL> = []
    private(set) var updateSelection: Set<String> = []
    private(set) var duplicateSelection: Set<URL> = []
    private(set) var largeOldFileSelection: Set<URL> = []
    private(set) var unusedAppSelection: Set<String> = []
    private(set) var leftoverSelection: Set<String> = []
    private(set) var installerSelection: Set<String> = []
    private(set) var browserPrivacySelection: Set<BrowserPrivacyKey> = []
    private(set) var similarImageSelection: Set<URL> = []
    private(set) var downloadSelection: Set<URL> = []
    private(set) var unsupportedAppSelection: Set<String> = []

    // MARK: - Private state

    /// Latest progress count per unit; `scannedItemCount` is their sum.
    @ObservationIgnored private var unitProgressCounts: [CareScanUnit: Int] = [:]

    /// Incremented at the start of every scan so an event that hops back to
    /// the main actor after a newer scan (or a reset) began is dropped.
    @ObservationIgnored private var scanGeneration = 0

    @ObservationIgnored private let scanEngine: ScanEngine
    @ObservationIgnored private let junkCleaner: JunkCleaner
    @ObservationIgnored private let threatRemover: ThreatRemover
    @ObservationIgnored private let updateOpener: UpdateOpener
    @ObservationIgnored private let recycleFiles: RecycleFiles
    @ObservationIgnored private let maintenanceTaskRunner: MaintenanceTaskRunner
    @ObservationIgnored private let recordMaintenanceRun: (String) -> Void
    @ObservationIgnored private let privacyRemover: PrivacyRemover
    @ObservationIgnored private let malwareEngineAvailable: () -> Bool
    /// "Customize Smart Care" gates, read once per `scan()` (snapshot, like
    /// the exclusions store) so a preference change applies to the next scan.
    @ObservationIgnored private let enabledDomains: () -> Set<CareDomain>
    @ObservationIgnored private let enabledUnits: () -> Set<CareScanUnit>
    @ObservationIgnored private let enabledJunkCategories: () -> Set<ScanCategory>

    /// History hooks, stamped when a scan lands and when a Run pass
    /// completes. No-ops by default; `live()` wires the app-scoped
    /// `CareHistoryStore` (which the feed and receipt views read directly).
    @ObservationIgnored private let recordScan: (Date) -> Void
    @ObservationIgnored private let recordReceipt: (CareReceipt) -> Void

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "SmartScanViewModel")

    init(
        scanEngine: @escaping ScanEngine,
        junkCleaner: @escaping JunkCleaner = { _ in 0 },
        threatRemover: @escaping ThreatRemover = { _ in [] },
        updateOpener: @escaping UpdateOpener = { _ in },
        recycleFiles: @escaping RecycleFiles = { _ in [] },
        maintenanceTaskRunner: @escaping MaintenanceTaskRunner = { _ in },
        recordMaintenanceRun: @escaping (String) -> Void = { _ in },
        privacyRemover: @escaping PrivacyRemover = { _ in },
        malwareEngineAvailable: @escaping () -> Bool = { true },
        enabledDomains: @escaping () -> Set<CareDomain> = { Set(CareDomain.allCases) },
        enabledUnits: @escaping () -> Set<CareScanUnit> = { Set(CareScanUnit.allCases) },
        enabledJunkCategories: @escaping () -> Set<ScanCategory> = { Set(SmartScanSettingsStore.junkCategories) },
        recordScan: @escaping (Date) -> Void = { _ in },
        recordReceipt: @escaping (CareReceipt) -> Void = { _ in }
    ) {
        self.recordScan = recordScan
        self.recordReceipt = recordReceipt
        self.scanEngine = scanEngine
        self.junkCleaner = junkCleaner
        self.threatRemover = threatRemover
        self.updateOpener = updateOpener
        self.recycleFiles = recycleFiles
        self.maintenanceTaskRunner = maintenanceTaskRunner
        self.recordMaintenanceRun = recordMaintenanceRun
        self.privacyRemover = privacyRemover
        self.malwareEngineAvailable = malwareEngineAvailable
        self.enabledDomains = enabledDomains
        self.enabledUnits = enabledUnits
        self.enabledJunkCategories = enabledJunkCategories
    }

    // MARK: - Scan

    /// Runs one Smart Scan through the engine and lands `.results` (or
    /// `.failed` when every attempted unit failed — a partially-broken scan
    /// still shows what it found). Re-entrant calls while a scan or Run is
    /// in flight are ignored; the guard reads synchronously before the first
    /// `await`, so it is reliable under `@MainActor`.
    func scan() async {
        switch phase {
        case .scanning, .running:
            return
        case .idle, .results, .done, .failed:
            break
        }

        scanGeneration += 1
        let generation = scanGeneration
        clearScanState()

        let domains = enabledDomains()
        // A unit runs only when both its domain and the unit itself are on — the
        // per-feature checkboxes narrow within an enabled domain.
        var units = Set(domains.flatMap(\.units)).intersection(enabledUnits())
        // Health telemetry is instant and non-destructive — it always rides
        // along so the verdict hero has a base tier.
        units.insert(.healthSnapshot)
        let configuration = CareScanEngine.Configuration(
            enabledUnits: units,
            enabledJunkCategories: enabledJunkCategories(),
            malwareEngineAvailable: malwareEngineAvailable()
        )

        unitStatuses = Dictionary(uniqueKeysWithValues: CareScanUnit.allCases.map { ($0, .pending) })
        phase = .scanning

        let plan = await scanEngine(configuration) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, generation: generation)
            }
        }

        guard generation == scanGeneration, case .scanning = phase else { return }
        await land(plan)
    }

    /// Applies one engine event to the checklist state. Events from a
    /// superseded scan, or arriving after the scan left `.scanning`, are
    /// dropped — the engine already clamps progress monotonic per unit.
    private func handle(_ event: CareScanEngine.Event, generation: Int) {
        guard generation == scanGeneration, case .scanning = phase else { return }
        switch event {
        case .unitStarted(let unit):
            unitStatuses[unit] = .running(itemsScanned: 0)
        case .unitProgress(let unit, let count):
            unitStatuses[unit] = .running(itemsScanned: count)
            unitProgressCounts[unit] = count
            scannedItemCount = unitProgressCounts.values.reduce(0, +)
        case .unitFinished(let unit, let outcome, let finding):
            unitStatuses[unit] = .finished(outcome)
            if let finding, !finding.isEmpty {
                liveFindings[finding.kind] = finding
            }
        }
    }

    /// Lands a completed plan: decide failed-vs-results, warm the junk
    /// manager store, and seed every selection tier off-main where the data
    /// can be large.
    private func land(_ plan: CarePlan) async {
        let attempted = CareScanUnit.allCases.filter { unit in
            switch plan.unitOutcomes[unit] {
            case .completed, .failed: return true
            case .skipped, nil: return false
            }
        }
        let allFailed = attempted.allSatisfy { unit in
            if case .failed = plan.unitOutcomes[unit] { return true }
            return false
        }
        if attempted.isEmpty || allFailed {
            let message = plan.failedUnits.compactMap { unit -> String? in
                if case .failed(let message)? = plan.unitOutcomes[unit] { return message }
                return nil
            }.first ?? String(
                localized: "The scan couldn't check anything this time.",
                comment: "Fallback failure message when every scan unit failed."
            )
            log.error("Smart Scan failed: every attempted unit failed")
            junkManagerStore.unload()
            phase = .failed(message: message)
            return
        }

        let junkResult: ScanResult
        if case .junk(let result)? = plan.finding(.junkCleanup)?.payload {
            junkResult = result
        } else {
            junkResult = ScanResult(items: [])
        }
        // Warm the junk Review's manager model in the background right away,
        // so its panes are instant by the time the user opens Review.
        junkManagerStore.load(result: junkResult)

        // Pre-check only the safe (regenerable / already-discarded) junk
        // categories so a one-tap Run never removes user data. Built off the
        // main actor — hashing a large result's URLs here froze the
        // scan-complete transition for seconds.
        let seed = await ScanSelectionSeed.safeDefaults(from: junkResult)
        junkFileSelection = seed.urls
        selectedJunkBytes = seed.totalBytes
        selectedJunkBytesByCategory = seed.bytesByCategory
        selectedJunkCountByCategory = seed.countByCategory

        if case .threats(let threats)? = plan.finding(.threats)?.payload {
            threatSelection = Set(threats.map(\.filePath))
        }
        if case .appUpdates(let updates)? = plan.finding(.appUpdates)?.payload {
            updateSelection = Set(updates.map(\.bundleID))
        }
        // Every redundant copy (never the kept original) — a copy always
        // survives, so default-on is safe.
        if case .duplicates(let groups)? = plan.finding(.duplicates)?.payload {
            duplicateSelection = Set(groups.flatMap { $0.redundantCopies.map(\.url) })
        }
        // Opt-in tiers (large/old files, unused apps, leftovers, installers,
        // browser privacy) stay empty: these are the user's own files and
        // data, and nothing is removed unless they choose it.

        includedFindings = Set(
            plan.findings
                .filter { $0.actionability == .preApproved && !$0.isEmpty }
                .map(\.kind)
        )

        phase = .results(plan)
        recordScan(plan.finishedAt)
        onScanCompleted?(plan)
    }

    /// Resets every per-scan accumulator ahead of a fresh scan.
    private func clearScanState() {
        unitStatuses = [:]
        liveFindings = [:]
        unitProgressCounts = [:]
        scannedItemCount = 0
        includedFindings = []
        isReviewing = false
        isConfirmingRun = false
        junkFileSelection = []
        selectedJunkBytes = 0
        selectedJunkBytesByCategory = [:]
        selectedJunkCountByCategory = [:]
        threatSelection = []
        updateSelection = []
        duplicateSelection = []
        similarImageSelection = []
        downloadSelection = []
        unsupportedAppSelection = []
        largeOldFileSelection = []
        unusedAppSelection = []
        leftoverSelection = []
        installerSelection = []
        browserPrivacySelection = []
    }

    // MARK: - Checklist derivation

    /// The domains this scan shows as checklist rows, in display order.
    var checklistDomains: [CareDomain] { CareDomain.allCases }

    /// One checklist row's rolled-up state. A domain is running while any of
    /// its units run, finished (with its plain result line) once all landed,
    /// skipped when every unit was skipped, and failed when any unit failed.
    func domainStatus(_ domain: CareDomain) -> DomainStatus {
        let statuses = domain.units.map { unitStatuses[$0] ?? .pending }
        var outcomes: [CareUnitOutcome] = []
        for status in statuses {
            if case .finished(let outcome) = status { outcomes.append(outcome) }
        }
        if outcomes.count == statuses.count {
            if outcomes.allSatisfy({ outcome in
                if case .skipped = outcome { return true }
                return false
            }) {
                return .skipped
            }
            if outcomes.contains(where: { outcome in
                if case .failed = outcome { return true }
                return false
            }) {
                return .failed
            }
            return .finished(
                line: CareFindingCopy.domainResultLine(domain, findings: Array(liveFindings.values))
            )
        }
        let running = domain.units.reduce(into: 0) { total, unit in
            if case .running(let items) = unitStatuses[unit] { total += items }
            else if let count = unitProgressCounts[unit] { total += count }
        }
        let anyRunning = statuses.contains { status in
            if case .running = status { return true }
            return false
        }
        // A domain with some units landed and none currently running is
        // between units in its lane — still "running" from the user's seat.
        let anyFinished = !outcomes.isEmpty
        return (anyRunning || anyFinished) ? .running(itemsScanned: running) : .pending
    }

    // MARK: - Results derivation

    /// The plan on screen, or `nil` outside `.results`.
    var currentPlan: CarePlan? {
        if case .results(let plan) = phase { return plan }
        return nil
    }

    /// Cheap phase identity for `onChange`/`animation` values. Comparing the
    /// full `Phase` drags the entire `CarePlan` (findings, per-unit outcome
    /// maps, a potentially million-item junk result) through `Equatable` on
    /// every render — this string answers "did the phase change?" for free.
    var phaseID: String {
        switch phase {
        case .idle:     return "idle"
        case .scanning: return "scanning"
        case .results:  return "results"
        case .running:  return "running"
        case .done:     return "done"
        case .failed:   return "failed"
        }
    }

    /// The hero verdict for the current results, derived on demand (pure and
    /// cheap) so it can never disagree with the plan on screen.
    var verdict: CareVerdict? {
        currentPlan.map(CareVerdictEngine.verdict(for:))
    }

    /// The feed in display order: threats first, then space, then advisories.
    var rankedFindings: [CareFinding] {
        currentPlan.map { CarePlanRanker.ranked($0.findings) } ?? []
    }

    // MARK: - Card inclusion

    func isFindingIncluded(_ kind: CareFinding.Kind) -> Bool {
        includedFindings.contains(kind)
    }

    /// How many items the user's review selection currently covers for a
    /// finding — the feed uses this to deep-link an opt-in card with nothing
    /// selected into Review instead of silently selecting everything.
    func selectionCount(for kind: CareFinding.Kind) -> Int {
        switch kind {
        case .junkCleanup: return junkFileSelection.count
        case .threats: return threatSelection.count
        case .appUpdates: return updateSelection.count
        case .duplicates: return duplicateSelection.count
        case .largeOldFiles: return largeOldFileSelection.count
        case .unusedApps: return unusedAppSelection.count
        case .appLeftovers: return leftoverSelection.count
        case .installers: return installerSelection.count
        case .browserPrivacy: return browserPrivacySelection.count
        case .similarImages: return similarImageSelection.count
        case .downloads: return downloadSelection.count
        case .unsupportedApps: return unsupportedAppSelection.count
        case .maintenanceDue: return currentPlan?.finding(.maintenanceDue)?.itemCount ?? 0
        case .loginItems, .lowDiskSpace, .extensions, .backgroundItems: return 0
        }
    }

    /// Sets a card's inclusion in the Run pass. Informational findings never
    /// join. The feed only calls this with `true` for an opt-in card when its
    /// selection is non-empty (otherwise it deep-links into Review).
    func setFindingIncluded(_ kind: CareFinding.Kind, _ included: Bool) {
        guard let finding = currentPlan?.finding(kind),
              finding.actionability != .informational else { return }
        if included {
            includedFindings.insert(kind)
        } else {
            includedFindings.remove(kind)
        }
    }

    /// Opt-in cards follow their review selection: items checked → card on,
    /// selection cleared → card off. Called by every opt-in selection setter.
    private func syncOptInInclusion(_ kind: CareFinding.Kind, hasSelection: Bool) {
        if hasSelection {
            includedFindings.insert(kind)
        } else {
            includedFindings.remove(kind)
        }
    }

    // MARK: - Junk selection (shared contract with the Cleanup Manager)

    /// The junk scan on screen, or an empty result outside `.results`.
    var junkResult: ScanResult {
        if case .junk(let result)? = currentPlan?.finding(.junkCleanup)?.payload { return result }
        return ScanResult(items: [])
    }

    /// Per-category view of `junkFileSelection`: a category counts as
    /// selected when every one of its files is selected.
    var junkCategorySelection: Set<ScanCategory> {
        Set(junkResult.itemsByCategory.compactMap { category, files in
            files.allSatisfy { junkFileSelection.contains($0.url) } ? category : nil
        })
    }

    func isJunkFileSelected(_ file: ScannedFile) -> Bool {
        junkFileSelection.contains(file.url)
    }

    /// Selected junk bytes in one category — an O(1) read backing the
    /// Cleanup Manager's per-category selected-size badge.
    func selectedJunkBytes(in category: ScanCategory) -> Int64 {
        selectedJunkBytesByCategory[category] ?? 0
    }

    /// Selected junk file count in one category — an O(1) read backing the
    /// bulk-select menu's None/All/Some state.
    func selectedJunkCount(in category: ScanCategory) -> Int {
        selectedJunkCountByCategory[category] ?? 0
    }

    /// Whether every file in `files` is currently selected. Short-circuits on
    /// the first unselected file.
    func areAllJunkFilesSelected(_ files: [ScannedFile]) -> Bool {
        !files.isEmpty && files.allSatisfy { junkFileSelection.contains($0.url) }
    }

    func toggleJunkFile(_ file: ScannedFile) {
        setJunkFiles([file], selected: !junkFileSelection.contains(file.url))
    }

    /// Toggle a whole group of files as one unit — the Cleanup Manager's
    /// folder-row checkbox. A fully-selected group clears; otherwise the
    /// whole group is selected.
    func toggleJunkFiles(_ files: [ScannedFile]) {
        setJunkFiles(files, selected: !areAllJunkFilesSelected(files))
    }

    /// Select or clear a group of junk files in a single pass, writing each
    /// observable property exactly once. Toggling a folder covering tens of
    /// thousands of files one at a time re-hashes each URL and fires an
    /// observation mutation per file — the work that froze the Cleanup
    /// Manager on large folders.
    func setJunkFiles(_ files: [ScannedFile], selected: Bool) {
        guard !files.isEmpty else { return }
        var urls = junkFileSelection
        var total = selectedJunkBytes
        var bytes = selectedJunkBytesByCategory
        var counts = selectedJunkCountByCategory
        for file in files {
            if selected {
                guard urls.insert(file.url).inserted else { continue }
                total += file.size
                bytes[file.category, default: 0] += file.size
                counts[file.category, default: 0] += 1
            } else {
                guard urls.remove(file.url) != nil else { continue }
                total -= file.size
                bytes[file.category, default: 0] -= file.size
                counts[file.category, default: 0] -= 1
            }
        }
        junkFileSelection = urls
        selectedJunkBytes = total
        selectedJunkBytesByCategory = bytes
        selectedJunkCountByCategory = counts
    }

    func isJunkCategorySelected(_ category: ScanCategory) -> Bool {
        junkCategorySelection.contains(category)
    }

    /// Toggling a category is a bulk operation over its files: fully selected
    /// clears, anything less selects all.
    func toggleJunkCategory(_ category: ScanCategory) {
        guard let files = junkResult.itemsByCategory[category] else { return }
        setJunkFiles(files, selected: !areAllJunkFilesSelected(files))
    }

    /// Check or uncheck every file in a category in one write — backs the
    /// Cleanup Manager's "Select: All / None" menu.
    func setJunkCategory(_ category: ScanCategory, selected: Bool) {
        guard let files = junkResult.itemsByCategory[category] else { return }
        setJunkFiles(files, selected: selected)
    }

    // MARK: - Threat selection

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

    /// Check or uncheck every detected threat in one write.
    func setAllThreats(selected: Bool) {
        guard case .threats(let threats)? = currentPlan?.finding(.threats)?.payload else { return }
        threatSelection = selected ? Set(threats.map(\.filePath)) : []
    }

    // MARK: - Update selection

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

    /// Check or uncheck every available update in one write.
    func setAllUpdates(selected: Bool) {
        guard case .appUpdates(let updates)? = currentPlan?.finding(.appUpdates)?.payload else { return }
        updateSelection = selected ? Set(updates.map(\.bundleID)) : []
    }

    // MARK: - Duplicate selection

    func isDuplicateSelected(_ file: ScannedFile) -> Bool {
        duplicateSelection.contains(file.url)
    }

    func toggleDuplicate(_ file: ScannedFile) {
        if duplicateSelection.contains(file.url) {
            duplicateSelection.remove(file.url)
        } else {
            duplicateSelection.insert(file.url)
        }
    }

    /// Check or uncheck a specific set of duplicate copies in one write.
    func setDuplicates(_ urls: [URL], selected: Bool) {
        if selected {
            duplicateSelection.formUnion(urls)
        } else {
            duplicateSelection.subtract(urls)
        }
    }

    /// Select every redundant copy in one write (kept originals are never
    /// included, so a copy always survives).
    func selectAllDuplicates() {
        guard case .duplicates(let groups)? = currentPlan?.finding(.duplicates)?.payload else { return }
        duplicateSelection = Set(groups.flatMap { $0.redundantCopies.map(\.url) })
    }

    func clearDuplicateSelection() {
        duplicateSelection = []
    }

    // MARK: - Similar image selection (opt-in)

    func isSimilarImageSelected(_ file: ScannedFile) -> Bool {
        similarImageSelection.contains(file.url)
    }

    func toggleSimilarImage(_ file: ScannedFile) {
        setSimilarImages([file.url], selected: !similarImageSelection.contains(file.url))
    }

    /// Check or uncheck a set of similar-image copies in one write. The best
    /// shot (the group's kept original) is never offered, so a photo always
    /// survives.
    func setSimilarImages(_ urls: [URL], selected: Bool) {
        if selected {
            similarImageSelection.formUnion(urls)
        } else {
            similarImageSelection.subtract(urls)
        }
        syncOptInInclusion(.similarImages, hasSelection: !similarImageSelection.isEmpty)
    }

    // MARK: - Downloads selection (opt-in)

    func isDownloadSelected(_ item: DownloadItem) -> Bool {
        downloadSelection.contains(item.file.url)
    }

    func toggleDownload(_ item: DownloadItem) {
        setDownloads([item.file.url], selected: !downloadSelection.contains(item.file.url))
    }

    /// Check or uncheck a set of downloads in one write.
    func setDownloads(_ urls: [URL], selected: Bool) {
        if selected {
            downloadSelection.formUnion(urls)
        } else {
            downloadSelection.subtract(urls)
        }
        syncOptInInclusion(.downloads, hasSelection: !downloadSelection.isEmpty)
    }

    // MARK: - Opt-in selections (large/old files, apps, installers, privacy)

    func isLargeOldFileSelected(_ file: ScannedFile) -> Bool {
        largeOldFileSelection.contains(file.url)
    }

    func toggleLargeOldFile(_ file: ScannedFile) {
        setLargeOldFiles([file.url], selected: !largeOldFileSelection.contains(file.url))
    }

    /// Check or uncheck a set of large/old files in one write.
    func setLargeOldFiles(_ urls: [URL], selected: Bool) {
        if selected {
            largeOldFileSelection.formUnion(urls)
        } else {
            largeOldFileSelection.subtract(urls)
        }
        syncOptInInclusion(.largeOldFiles, hasSelection: !largeOldFileSelection.isEmpty)
    }

    func isUnusedAppSelected(_ app: UnusedApp) -> Bool {
        unusedAppSelection.contains(app.id)
    }

    func toggleUnusedApp(_ app: UnusedApp) {
        setUnusedApps([app.id], selected: !unusedAppSelection.contains(app.id))
    }

    func setUnusedApps(_ ids: [String], selected: Bool) {
        if selected {
            unusedAppSelection.formUnion(ids)
        } else {
            unusedAppSelection.subtract(ids)
        }
        syncOptInInclusion(.unusedApps, hasSelection: !unusedAppSelection.isEmpty)
    }

    func isUnsupportedAppSelected(_ app: UnsupportedApp) -> Bool {
        unsupportedAppSelection.contains(app.id)
    }

    func toggleUnsupportedApp(_ app: UnsupportedApp) {
        setUnsupportedApps([app.id], selected: !unsupportedAppSelection.contains(app.id))
    }

    func setUnsupportedApps(_ ids: [String], selected: Bool) {
        if selected {
            unsupportedAppSelection.formUnion(ids)
        } else {
            unsupportedAppSelection.subtract(ids)
        }
        syncOptInInclusion(.unsupportedApps, hasSelection: !unsupportedAppSelection.isEmpty)
    }

    func isLeftoverSelected(_ group: LeftoverGroup) -> Bool {
        leftoverSelection.contains(group.bundleID)
    }

    func toggleLeftover(_ group: LeftoverGroup) {
        setLeftovers([group.bundleID], selected: !leftoverSelection.contains(group.bundleID))
    }

    func setLeftovers(_ bundleIDs: [String], selected: Bool) {
        if selected {
            leftoverSelection.formUnion(bundleIDs)
        } else {
            leftoverSelection.subtract(bundleIDs)
        }
        syncOptInInclusion(.appLeftovers, hasSelection: !leftoverSelection.isEmpty)
    }

    func isInstallerSelected(_ file: InstallationFile) -> Bool {
        installerSelection.contains(file.id)
    }

    func toggleInstaller(_ file: InstallationFile) {
        setInstallers([file.id], selected: !installerSelection.contains(file.id))
    }

    func setInstallers(_ ids: [String], selected: Bool) {
        if selected {
            installerSelection.formUnion(ids)
        } else {
            installerSelection.subtract(ids)
        }
        syncOptInInclusion(.installers, hasSelection: !installerSelection.isEmpty)
    }

    func isBrowserPrivacySelected(_ key: BrowserPrivacyKey) -> Bool {
        browserPrivacySelection.contains(key)
    }

    /// Only removable categories are selectable; the informational ones
    /// (passwords, autofill, history) are shown for awareness and can never
    /// join the Run pass.
    func toggleBrowserPrivacy(_ key: BrowserPrivacyKey) {
        guard key.category.kind == .removable else { return }
        if browserPrivacySelection.contains(key) {
            browserPrivacySelection.remove(key)
        } else {
            browserPrivacySelection.insert(key)
        }
        syncOptInInclusion(.browserPrivacy, hasSelection: !browserPrivacySelection.isEmpty)
    }

    // MARK: - Executable work surface

    /// Whether the given finding would actually do work if Run were pressed:
    /// its card must be included and its selection must cover at least one
    /// item. Read by the feed's captions and the floating Run disc's gate.
    func willExecute(_ kind: CareFinding.Kind) -> Bool {
        guard currentPlan?.finding(kind) != nil, includedFindings.contains(kind) else { return false }
        switch kind {
        case .maintenanceDue:
            return (currentPlan?.finding(.maintenanceDue)?.itemCount ?? 0) > 0
        case .loginItems, .lowDiskSpace:
            return false
        default:
            return selectionCount(for: kind) > 0
        }
    }

    /// `true` iff at least one included finding would actually do work. The
    /// floating Run disc gates its visibility on this.
    var hasExecutableWork: Bool {
        CareFinding.Kind.allCases.contains { willExecute($0) }
    }

    /// How many included findings would do work on a Run pass — the count the
    /// disc's caption shows ("N items"). Kept live so toggling a card updates
    /// it immediately.
    var runnableFindingCount: Int {
        CareFinding.Kind.allCases.count { willExecute($0) }
    }

    /// Bytes a Run pass would free right now, summed from each runnable
    /// finding's current selection — the size the disc's caption shows. Only
    /// findings that carry a measured size contribute (junk dominates); the
    /// rest (updates, maintenance, threats) free no disk space and count zero.
    var freeableBytes: Int64 {
        CareFinding.Kind.allCases.reduce(0) { total, kind in
            willExecute(kind) ? total + selectedBytes(for: kind) : total
        }
    }

    /// Whether the pending Run pass includes a permanent delete. Junk cleanup
    /// is the only action that bypasses the Trash (macOS rebuilds it), so it
    /// is the only thing the confirmation sheet needs to flag as irreversible.
    var runIncludesPermanentDelete: Bool {
        willExecute(.junkCleanup)
    }

    /// Selected bytes for one finding, mirroring the size sources `execute`
    /// uses so the caption's total matches what the receipt will report.
    private func selectedBytes(for kind: CareFinding.Kind) -> Int64 {
        guard let payload = currentPlan?.finding(kind)?.payload else { return 0 }
        switch payload {
        case .junk:
            return selectedJunkBytes
        case .duplicates(let groups):
            return selectedBytes(in: duplicateSelection, sizes: groups.flatMap { $0.files.map { ($0.url, $0.size) } })
        case .largeOldFiles(let files):
            return selectedBytes(in: largeOldFileSelection, sizes: files.map { ($0.url, $0.size) })
        case .similarImages(let groups):
            return selectedBytes(in: similarImageSelection, sizes: groups.flatMap { $0.files.map { ($0.url, $0.size) } })
        case .downloads(let items):
            return selectedBytes(in: downloadSelection, sizes: items.map { ($0.file.url, $0.file.size) })
        case .installers(let files):
            return files.filter { installerSelection.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
        case .unusedApps(let apps):
            return apps.filter { unusedAppSelection.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
        case .appLeftovers(let groups):
            return groups.filter { leftoverSelection.contains($0.bundleID) }.reduce(0) { $0 + $1.totalBytes }
        case .threats, .appUpdates, .maintenanceDue, .unsupportedApps, .browserPrivacy,
             .loginItems, .lowDiskSpace, .extensions, .backgroundItems:
            return 0
        }
    }

    /// Sums the sizes of the selected URLs against a (url, size) list.
    private func selectedBytes(in selection: Set<URL>, sizes: [(URL, Int64)]) -> Int64 {
        let table = Dictionary(sizes, uniquingKeysWith: { first, _ in first })
        return selection.reduce(0) { $0 + (table[$1] ?? 0) }
    }

    /// Whether the floating Run disc should be on screen: only on the
    /// results feed, only with work to do, and never while a Review or the
    /// confirmation sheet is up.
    var isRunDiscVisible: Bool {
        guard case .results = phase else { return false }
        return hasExecutableWork && !isReviewing && !isConfirmingRun
    }

    /// Records whether a Review screen is open, so the floating Run disc can
    /// hide while the user is inside one. Driven by `SmartScanView`.
    func setReviewing(_ isReviewing: Bool) {
        self.isReviewing = isReviewing
    }

    // MARK: - Run

    /// The disc's tap entry point. Runs immediately when nothing irreversible
    /// is included, but raises the confirmation sheet first when the pass would
    /// permanently delete junk — the one step the Trash can't undo. A no-op
    /// unless the results feed has work to do.
    func requestRun() async {
        guard case .results = phase, hasExecutableWork else { return }
        if runIncludesPermanentDelete {
            isConfirmingRun = true
        } else {
            await run()
        }
    }

    /// Confirms a run the sheet was gating and starts it.
    func confirmRun() async {
        guard isConfirmingRun else { return }
        isConfirmingRun = false
        await run()
    }

    /// Dismisses the confirmation sheet without running.
    func cancelRun() {
        isConfirmingRun = false
    }

    /// One line per finding the pending run would act on, in feed order — the
    /// body of the confirmation sheet. Each says what will happen to the chosen
    /// items; the permanent one is flagged so the sheet can mark it.
    var runActionSummary: [RunActionLine] {
        CarePlanRanker.ranked(currentPlan?.findings ?? [])
            .filter { willExecute($0.kind) }
            .map { finding in
                RunActionLine(
                    kind: finding.kind,
                    text: CareFindingCopy.runConfirmationLine(
                        for: finding.kind,
                        bytes: selectedBytes(for: finding.kind),
                        count: selectionCount(for: finding.kind)
                    ),
                    isPermanent: finding.kind == .junkCleanup
                )
            }
    }

    /// One Run pass over the included findings, in feed order. Every finding
    /// executes inside its own do/catch and lands one receipt line, so a
    /// single failure leaves the rest of the pass intact. A no-op unless the
    /// results feed is showing.
    func run() async {
        guard case .results(let plan) = phase else { return }
        phase = .running

        var lines: [CareReceiptLine] = []
        for finding in CarePlanRanker.ranked(plan.findings) where willExecuteDuringRun(finding) {
            if let line = await execute(finding, plan: plan) {
                lines.append(line)
            }
        }
        let receipt = CareReceipt(date: Date(), lines: lines)
        recordReceipt(receipt)
        phase = .done(receipt: receipt)
    }

    /// `willExecute` reads `phase == .results`; during the pass the phase is
    /// `.running`, so Run re-checks inclusion and selection directly.
    private func willExecuteDuringRun(_ finding: CareFinding) -> Bool {
        guard includedFindings.contains(finding.kind) else { return false }
        switch finding.kind {
        case .maintenanceDue: return finding.itemCount > 0
        case .loginItems, .lowDiskSpace: return false
        default: return selectionCount(for: finding.kind) > 0
        }
    }

    private func execute(_ finding: CareFinding, plan: CarePlan) async -> CareReceiptLine? {
        switch finding.payload {
        case .junk(let result):
            // The full junk result is a million files on a busy Mac; filter
            // against the selection off the main actor — hashing that many
            // URLs on the main thread froze the Run tap.
            let selected = junkFileSelection
            let selectedJunk = await ScanFileFilter.selected(from: result.items) { selected.contains($0.url) }
            guard !selectedJunk.isEmpty else { return nil }
            do {
                let bytes = try await junkCleaner(selectedJunk)
                return CareReceiptLine(kind: .junkCleanup, itemsProcessed: selectedJunk.count, bytesFreed: bytes, outcome: .success)
            } catch {
                log.error("Smart Scan junk clean failed: \(String(describing: error), privacy: .public)")
                return CareReceiptLine(kind: .junkCleanup, itemsProcessed: 0, bytesFreed: 0, outcome: .failed(message: error.localizedDescription))
            }

        case .threats(let threats):
            let selected = threats.filter { threatSelection.contains($0.filePath) }
            guard !selected.isEmpty else { return nil }
            let failures = await threatRemover(selected)
            let removed = selected.count - failures.count
            return CareReceiptLine(
                kind: .threats,
                itemsProcessed: removed,
                bytesFreed: 0,
                outcome: failures.isEmpty ? .success : .partial(failedCount: failures.count)
            )

        case .duplicates(let groups):
            return await recycleLine(
                kind: .duplicates,
                urls: Array(duplicateSelection),
                sizeOf: Dictionary(
                    groups.flatMap { $0.files.map { ($0.url, $0.size) } },
                    uniquingKeysWith: { size, _ in size }
                )
            )

        case .similarImages(let groups):
            return await recycleLine(
                kind: .similarImages,
                urls: Array(similarImageSelection),
                sizeOf: Dictionary(
                    groups.flatMap { $0.files.map { ($0.url, $0.size) } },
                    uniquingKeysWith: { size, _ in size }
                )
            )

        case .downloads(let items):
            return await recycleLine(
                kind: .downloads,
                urls: Array(downloadSelection),
                sizeOf: Dictionary(items.map { ($0.file.url, $0.file.size) }, uniquingKeysWith: { size, _ in size })
            )

        case .largeOldFiles(let files):
            return await recycleLine(
                kind: .largeOldFiles,
                urls: Array(largeOldFileSelection),
                sizeOf: Dictionary(files.map { ($0.url, $0.size) }, uniquingKeysWith: { size, _ in size })
            )

        case .installers(let files):
            let selected = files.filter { installerSelection.contains($0.id) }
            return await recycleLine(
                kind: .installers,
                urls: selected.map(\.url),
                sizeOf: Dictionary(selected.map { ($0.url, $0.sizeBytes) }, uniquingKeysWith: { size, _ in size })
            )

        case .unusedApps(let apps):
            let selected = apps.filter { unusedAppSelection.contains($0.id) }
            return await recycleLine(
                kind: .unusedApps,
                urls: selected.map(\.app.bundleURL),
                sizeOf: Dictionary(selected.map { ($0.app.bundleURL, $0.sizeBytes) }, uniquingKeysWith: { size, _ in size })
            )

        case .unsupportedApps(let apps):
            // Incompatible apps carry no measured size (the value is removing a
            // dead app, not the space) — recycle the chosen bundles, credit 0.
            let selected = apps.filter { unsupportedAppSelection.contains($0.id) }
            return await recycleLine(
                kind: .unsupportedApps,
                urls: selected.map { $0.app.bundleURL },
                sizeOf: [:]
            )

        case .appLeftovers(let groups):
            let selected = groups.filter { leftoverSelection.contains($0.bundleID) }
            guard !selected.isEmpty else { return nil }
            let recycled = await recycleFiles(selected.flatMap(\.urls))
            // Byte credit per fully-recycled group — LeftoverGroup only
            // carries a group total, so a partial group credits nothing.
            let fullyRemoved = selected.filter { group in group.urls.allSatisfy(recycled.contains) }
            let outcome: CareReceiptLine.Outcome = fullyRemoved.count == selected.count
                ? .success
                : .partial(failedCount: selected.count - fullyRemoved.count)
            return CareReceiptLine(
                kind: .appLeftovers,
                itemsProcessed: fullyRemoved.count,
                bytesFreed: fullyRemoved.reduce(0) { $0 + $1.totalBytes },
                outcome: outcome
            )

        case .appUpdates(let updates):
            let selected = updates.filter { updateSelection.contains($0.bundleID) }
            guard !selected.isEmpty else { return nil }
            for update in selected {
                await updateOpener(update.updateURL)
            }
            return CareReceiptLine(kind: .appUpdates, itemsProcessed: selected.count, bytesFreed: 0, outcome: .success)

        case .maintenanceDue(let taskIDs):
            guard !taskIDs.isEmpty else { return nil }
            var completed = 0
            var lastError: String?
            for taskID in taskIDs {
                do {
                    try await maintenanceTaskRunner(taskID)
                    recordMaintenanceRun(taskID)
                    completed += 1
                } catch {
                    log.error("Smart Scan maintenance task \(taskID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    lastError = error.localizedDescription
                }
            }
            let outcome: CareReceiptLine.Outcome
            if completed == taskIDs.count {
                outcome = .success
            } else if completed > 0 {
                outcome = .partial(failedCount: taskIDs.count - completed)
            } else {
                outcome = .failed(message: lastError ?? "")
            }
            return CareReceiptLine(kind: .maintenanceDue, itemsProcessed: completed, bytesFreed: 0, outcome: outcome)

        case .browserPrivacy:
            let selected = browserPrivacySelection
            guard !selected.isEmpty else { return nil }
            let requests = selected.map {
                PrivacyRemovalRequest(browser: $0.browser, category: $0.category, scope: .wholeCategory)
            }
            do {
                try await privacyRemover(requests)
                return CareReceiptLine(kind: .browserPrivacy, itemsProcessed: requests.count, bytesFreed: 0, outcome: .success)
            } catch let PrivacyRemovalError.browserRunning(browser) {
                let message = String.localizedStringWithFormat(
                    String(
                        localized: "Close %@ first, then try again.",
                        comment: "Receipt failure line when a browser must quit before its data can be cleared."
                    ),
                    browser.displayName
                )
                return CareReceiptLine(kind: .browserPrivacy, itemsProcessed: 0, bytesFreed: 0, outcome: .failed(message: message))
            } catch {
                log.error("Smart Scan browser privacy clear failed: \(String(describing: error), privacy: .public)")
                return CareReceiptLine(kind: .browserPrivacy, itemsProcessed: 0, bytesFreed: 0, outcome: .failed(message: error.localizedDescription))
            }

        case .loginItems, .lowDiskSpace, .extensions, .backgroundItems:
            return nil
        }
    }

    /// Shared Trash-based removal: recycle the URLs, credit the bytes that
    /// actually moved, report partial success honestly.
    private func recycleLine(
        kind: CareFinding.Kind,
        urls: [URL],
        sizeOf: [URL: Int64]
    ) async -> CareReceiptLine? {
        guard !urls.isEmpty else { return nil }
        let recycled = await recycleFiles(urls)
        let bytes = recycled.reduce(Int64(0)) { $0 + (sizeOf[$1] ?? 0) }
        let outcome: CareReceiptLine.Outcome = recycled.count == urls.count
            ? .success
            : .partial(failedCount: urls.count - recycled.count)
        if recycled.isEmpty {
            return CareReceiptLine(
                kind: kind,
                itemsProcessed: 0,
                bytesFreed: 0,
                outcome: .failed(message: String(
                    localized: "These files couldn't be moved to the Trash.",
                    comment: "Receipt failure line when no selected file could be recycled."
                ))
            )
        }
        return CareReceiptLine(kind: kind, itemsProcessed: recycled.count, bytesFreed: bytes, outcome: outcome)
    }

    // MARK: - Recovery

    /// Returns to idle from a terminal phase so the user can start over.
    /// Selections clear in lockstep so a fresh scan starts from the default
    /// seed rather than carrying the previous run's choices forward.
    func reset() {
        scanGeneration += 1
        phase = .idle
        junkManagerStore.unload()
        clearScanState()
    }
}

// MARK: - Production wiring

extension SmartScanViewModel {

    /// Builds a view model wired to the live `CareScanEngine` runners and the
    /// same cleanup collaborators the standalone sections use. The exclusions
    /// and Scanning-preferences snapshots are captured per scan so a change
    /// takes effect on the next run.
    @MainActor
    static func live(
        exclusions: ExclusionsStore,
        settings: SmartScanSettingsStore,
        webDevScanScope: WebDevScanScopeStore? = nil,
        statsService: SystemStatsService,
        history: CareHistoryStore? = nil,
        protectionSettings: ProtectionSettingsStore? = nil
    ) -> SmartScanViewModel {
        // Default arguments evaluate outside the main actor, so the fallback
        // store (previews, tests) is built here instead.
        let history = history ?? CareHistoryStore()
        let engine = CareScanEngine(
            runners: .live(
                exclusions: exclusions,
                webDevScanScope: webDevScanScope,
                statsService: statsService,
                protectionSettings: protectionSettings
            )
        )
        let detector = ClamAVDetector()
        let threatRemover = MalwareThreatRemover()
        let privacyRemover = BrowserPrivacyRemover(pathProvider: DefaultBrowserDataPathProvider())
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SmartScanViewModel.live")

        return SmartScanViewModel(
            scanEngine: { configuration, onEvent in
                await engine.scan(configuration: configuration, onEvent: onEvent)
            },
            junkCleaner: { try await SystemJunkDeleter().delete($0) },
            threatRemover: { await threatRemover.remove($0) },
            updateOpener: { url in
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            },
            recycleFiles: { urls in await Self.recycle(urls, log: log) },
            maintenanceTaskRunner: { taskID in
                switch MaintenanceTask.Kind(rawValue: taskID) {
                case .runMaintenanceScripts: _ = try await MaintenanceScriptRunner().run()
                case .flushDNS: _ = try await DNSCacheFlusher().run()
                case .reindexSpotlight: _ = try await SpotlightReindexer().run()
                case .speedUpMail: _ = try await MailReindexer().run()
                case .freeUpRAM, .thinTimeMachineSnapshots, nil:
                    // Not part of the maintenance cocktail Smart Scan runs.
                    break
                }
            },
            recordMaintenanceRun: { MaintenanceRunLog().record($0) },
            privacyRemover: { try await privacyRemover.remove($0) },
            malwareEngineAvailable: { detector.isInstalled() },
            enabledDomains: { [weak settings] in
                settings?.enabledDomains ?? Set(CareDomain.allCases)
            },
            enabledUnits: { [weak settings] in
                settings?.enabledUnits ?? Set(CareScanUnit.allCases)
            },
            enabledJunkCategories: { [weak settings] in
                settings?.enabledJunkCategories ?? Set(SmartScanSettingsStore.junkCategories)
            },
            // Strong captures: the view model is the store's writer, and the
            // app hands the same instance to the environment for the views.
            recordScan: { history.recordScan(at: $0) },
            recordReceipt: { history.recordReceipt($0) }
        )
    }

    /// Default recycler: move each file to the user's Trash via
    /// `NSWorkspace.recycle` (restorable) and return the URLs that actually
    /// moved. Marked `nonisolated` so a multi-gigabyte batch runs off the
    /// main actor. Failures are logged with hash-masked privacy.
    nonisolated private static func recycle(_ urls: [URL], log: Logger) async -> Set<URL> {
        guard !urls.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { trashed, error in
                if let error {
                    log.error("Smart Scan recycle reported: \(error.localizedDescription, privacy: .private(mask: .hash))")
                }
                continuation.resume(returning: Set(trashed.keys))
            }
        }
    }
}

// MARK: - ScanCoordinating

extension SmartScanViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. `.results`/`.running`/`.done`/`.failed` all want the
    /// section's own detail UI, whose internal switch renders the specifics.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .scanning:
            return .working
        case .results, .running, .done, .failed:
            return .results
        }
    }

    func beginScan() {
        runScanActivity { await self.scan() }
    }
}
