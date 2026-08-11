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

    /// Live progress of a Run pass so the running screen shows what's underway
    /// instead of a blind spinner: which action is running now, how far through
    /// the queue it is, and how much space has been freed so far.
    struct RunProgress: Equatable {
        /// Findings finished before the current one — a 0-based step index.
        var completed: Int
        /// Total findings the pass will act on.
        var total: Int
        /// Plain-language label for the action underway (e.g. "Clearing out junk…").
        var currentLabel: String
        /// Bytes freed by the findings completed so far.
        var bytesFreed: Int64
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
    /// An app's on-disk support files, by bundle ID — the same lookup the
    /// Uninstaller performs before it recycles a bundle, so uninstalling an
    /// unused app here takes its preferences, caches, and containers too.
    typealias FindAssociatedFiles = @Sendable (String) async -> [AssociatedFile]
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

    /// Live progress while `.running`, or `nil` outside a Run pass. Drives the
    /// running screen's action label, step count, and freed-so-far total.
    private(set) var runProgress: RunProgress?

    /// Whether a post-Fix re-check is in flight. The feed is on screen the whole
    /// time — the findings the pass consumed are simply off it until their
    /// re-scan lands — so this drives the note that says why, and holds the Run
    /// disc back until the plan is whole again.
    private(set) var isRefreshingFindings = false

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
    /// Keyed by `UpdateInfo.id` — the installed bundle's path — never by
    /// bundle ID. The same app can be installed in two locations, which is
    /// two rows in Review; a bundle-ID key would collapse them into one
    /// checkbox and open both downloads when the user chose one.
    private(set) var updateSelection: Set<UpdateInfo.ID> = []
    private(set) var maintenanceSelection: Set<String> = []
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

    /// The plan the Run pass acted on. Kept because the phase stops carrying it
    /// at `.running`, and Done needs it to hand the feed back every finding the
    /// run didn't touch.
    @ObservationIgnored private var planUnderRun: CarePlan?

    @ObservationIgnored private let scanEngine: ScanEngine
    @ObservationIgnored private let junkCleaner: JunkCleaner
    @ObservationIgnored private let threatRemover: ThreatRemover
    @ObservationIgnored private let updateOpener: UpdateOpener
    @ObservationIgnored private let recycleFiles: RecycleFiles
    @ObservationIgnored private let findAssociatedFiles: FindAssociatedFiles
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

    /// Past Run receipts, read when a plan lands so severity can tell work that
    /// has come back from work being seen for the first time.
    @ObservationIgnored private let pastReceipts: () -> [CareReceipt]

    /// Consecutive Run passes the user has left each kind alone, and the sink
    /// that folds one pass's choices back in. A finding acted on resets; one
    /// left behind grows its streak.
    @ObservationIgnored private let declineCounts: () -> [CareFinding.Kind: Int]
    @ObservationIgnored private let recordRunChoices: (Set<CareFinding.Kind>, Set<CareFinding.Kind>) -> Void

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "SmartScanViewModel")

    init(
        scanEngine: @escaping ScanEngine,
        junkCleaner: @escaping JunkCleaner = { _ in 0 },
        threatRemover: @escaping ThreatRemover = { _ in [] },
        updateOpener: @escaping UpdateOpener = { _ in },
        recycleFiles: @escaping RecycleFiles = { _ in [] },
        // Defaults to claiming nothing: a caller that supplies no finder
        // recycles bundles alone, which is what every test that isn't about
        // uninstalling an app wants.
        findAssociatedFiles: @escaping FindAssociatedFiles = { _ in [] },
        maintenanceTaskRunner: @escaping MaintenanceTaskRunner = { _ in },
        recordMaintenanceRun: @escaping (String) -> Void = { _ in },
        privacyRemover: @escaping PrivacyRemover = { _ in },
        malwareEngineAvailable: @escaping () -> Bool = { true },
        enabledDomains: @escaping () -> Set<CareDomain> = { Set(CareDomain.allCases) },
        enabledUnits: @escaping () -> Set<CareScanUnit> = { Set(CareScanUnit.allCases) },
        enabledJunkCategories: @escaping () -> Set<ScanCategory> = { Set(SmartScanSettingsStore.junkCategories) },
        recordScan: @escaping (Date) -> Void = { _ in },
        recordReceipt: @escaping (CareReceipt) -> Void = { _ in },
        pastReceipts: @escaping () -> [CareReceipt] = { [] },
        declineCounts: @escaping () -> [CareFinding.Kind: Int] = { [:] },
        recordRunChoices: @escaping (Set<CareFinding.Kind>, Set<CareFinding.Kind>) -> Void = { _, _ in }
    ) {
        self.recordScan = recordScan
        self.recordReceipt = recordReceipt
        self.pastReceipts = pastReceipts
        self.declineCounts = declineCounts
        self.recordRunChoices = recordRunChoices
        self.scanEngine = scanEngine
        self.junkCleaner = junkCleaner
        self.threatRemover = threatRemover
        self.updateOpener = updateOpener
        self.recycleFiles = recycleFiles
        self.findAssociatedFiles = findAssociatedFiles
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
        // Nothing left to look at. Health telemetry rides along below and would
        // otherwise carry this to a completed plan with no findings, where the
        // verdict hero reads "Nothing needs your attention right now." — a clean
        // bill of health for a scan that checked nothing. Say what happened and
        // where to fix it instead.
        guard !units.isEmpty else {
            log.error("Smart Scan refused: every scan area is disabled in Settings")
            phase = .failed(message: String(
                localized: "Every area is switched off in Settings → Scanning. Turn at least one back on and Smart Scan will have something to check.",
                comment: "Smart Scan failure message when the user has disabled every scan area."
            ))
            return
        }
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
    ///
    /// `stampHistory` is false for a post-Run refresh: a targeted re-check of
    /// what the run changed is not a new scan, and dating the user's scan
    /// history from it would overstate what was looked at.
    ///
    /// `seeding` names the units whose selections this landing may re-seed;
    /// `nil` (a fresh scan) seeds everything. A post-Run refresh passes the
    /// units it re-scanned, because everything else on the plan is the same
    /// finding the user was already looking at — and re-seeding those threw
    /// their decisions away. Duplicates seed fully checked, so unchecking them
    /// all is the only way to decline them; landing a merged plan put every
    /// copy back and re-included the card, and the next Fix would have trashed
    /// them.
    private func land(
        _ plan: CarePlan,
        stampHistory: Bool = true,
        seeding units: Set<CareScanUnit>? = nil
    ) async {
        // A new plan is arriving: drop anything memoized from the last one.
        invalidateResultsCaches()
        // A fresh scan re-seeds everything; a refresh only what it re-checked.
        let shouldSeed: (CareFinding.Kind) -> Bool = { kind in
            units?.contains(kind.unit) ?? true
        }
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

        if shouldSeed(.junkCleanup) {
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
        }

        if shouldSeed(.threats), case .threats(let threats)? = plan.finding(.threats)?.payload {
            threatSelection = Set(threats.map(\.filePath))
        }
        if shouldSeed(.appUpdates), case .appUpdates(let updates)? = plan.finding(.appUpdates)?.payload {
            updateSelection = Set(updates.map(\.id))
        }
        // Every due maintenance task starts selected — the tune-up tile is
        // pre-approved, so Run does the whole cocktail unless the user opts a
        // task out in Review.
        if shouldSeed(.maintenanceDue), case .maintenanceDue(let taskIDs)? = plan.finding(.maintenanceDue)?.payload {
            maintenanceSelection = Set(taskIDs)
        }
        // Every redundant copy (never the kept original) — a copy always
        // survives, so default-on is safe.
        if shouldSeed(.duplicates), case .duplicates(let groups)? = plan.finding(.duplicates)?.payload {
            duplicateSelection = Set(groups.flatMap { $0.redundantCopies.map(\.url) })
        }
        // Opt-in tiers (large/old files, unused apps, leftovers, installers,
        // browser privacy) stay empty: these are the user's own files and
        // data, and nothing is removed unless they choose it.

        includedFindings = inclusion(for: plan, seeding: units)

        phase = .results(plan)
        if stampHistory {
            recordScan(plan.finishedAt)
        }
        onScanCompleted?(plan)
    }

    /// Which cards are in the Run pass once `plan` lands.
    ///
    /// A fresh scan starts from the pre-approved findings. A refresh keeps what
    /// the user decided about every finding it did not re-scan — a card they
    /// opted out of stays out, an opt-in card they checked stays in — and takes
    /// the default only for the re-seeded ones. Carried inclusions are
    /// intersected with the merged plan so a finding that has since gone empty
    /// can't linger in the set.
    private func inclusion(for plan: CarePlan, seeding units: Set<CareScanUnit>?) -> Set<CareFinding.Kind> {
        let defaults = Set(
            plan.findings
                .filter { $0.actionability == .preApproved && !$0.isEmpty }
                .map(\.kind)
        )
        guard let units else { return defaults }
        let present = Set(plan.findings.map(\.kind))
        let carried = includedFindings.filter { !units.contains($0.unit) }.intersection(present)
        return carried.union(defaults.filter { units.contains($0.unit) })
    }

    /// Resets every per-scan accumulator ahead of a fresh scan.
    private func clearScanState() {
        unitStatuses = [:]
        liveFindings = [:]
        planUnderRun = nil
        isRefreshingFindings = false
        unitProgressCounts = [:]
        scannedItemCount = 0
        includedFindings = []
        isReviewing = false
        isConfirmingRun = false
        runProgress = nil
        junkFileSelection = []
        selectedJunkBytes = 0
        selectedJunkBytesByCategory = [:]
        selectedJunkCountByCategory = [:]
        threatSelection = []
        updateSelection = []
        maintenanceSelection = []
        duplicateSelection = []
        similarImageSelection = []
        downloadSelection = []
        unsupportedAppSelection = []
        largeOldFileSelection = []
        unusedAppSelection = []
        leftoverSelection = []
        installerSelection = []
        browserPrivacySelection = []
        invalidateResultsCaches()
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
            if case .running(let items) = unitStatuses[unit] { total += items } else if let count = unitProgressCounts[unit] { total += count }
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

    /// Memoized derivations for the plan on screen. `@ObservationIgnored` so
    /// filling one during a render can't invalidate the views reading it;
    /// `invalidateResultsCaches()` drops both whenever a new plan lands.
    @ObservationIgnored private var rankedFindingsCache: [CareFinding]?
    @ObservationIgnored private var sizeTables: [CareFinding.Kind: [URL: Int64]] = [:]
    @ObservationIgnored private var severityContextCache: CareSeverityContext?

    /// The severity inputs for the plan on screen. Snapshotted on first read
    /// rather than rebuilt per access: `now` anchors every receipt age, and a
    /// clock that advances between reads would let the feed reorder itself
    /// under the user mid-session.
    var severityContext: CareSeverityContext {
        if let cached = severityContextCache { return cached }
        let context = CareSeverityContext(
            health: currentPlan?.health,
            receipts: pastReceipts(),
            now: Date(),
            declines: declineCounts()
        )
        severityContextCache = context
        return context
    }

    /// The feed in display order: threats first, then space, then advisories.
    /// Memoized per plan: the feed reads this several times in one render (once
    /// for emptiness, then once per actionability zone), and re-sorting the
    /// findings on every read is work each return from a Manager paid for.
    var rankedFindings: [CareFinding] {
        guard let plan = currentPlan else { return [] }
        if let cached = rankedFindingsCache { return cached }
        let ranked = CarePlanRanker.ranked(plan.findings, context: severityContext)
        rankedFindingsCache = ranked
        return ranked
    }

    @ObservationIgnored private var severityCache: [CareFinding.Kind: CareSeverity] = [:]

    /// This finding's severity under the current plan's context. Memoized for
    /// the same render-cost reason as `rankedFindings`: every tile reads it on
    /// every pass through the feed.
    func severity(for finding: CareFinding) -> CareSeverity {
        if let cached = severityCache[finding.kind] { return cached }
        let value = CareSeverityEngine.severity(for: finding, context: severityContext)
        severityCache[finding.kind] = value
        return value
    }

    /// Drops the per-plan memoizations so a stale sort or size table can never
    /// outlive the results it was built from.
    private func invalidateResultsCaches() {
        rankedFindingsCache = nil
        sizeTables = [:]
        severityContextCache = nil
        severityCache = [:]
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
        case .maintenanceDue: return maintenanceSelection.count
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

    /// The one write path behind every per-finding `set…(_:selected:)` below:
    /// apply a batch change to that finding's id set, then keep its card's
    /// inclusion in step with whether anything is still checked.
    ///
    /// Each finding keeps its own named accessors — that vocabulary is what the
    /// Review screens and the tests speak — but they all funnel through here, so
    /// the "checking something opts the card in, clearing it opts back out" rule
    /// lives in exactly one place rather than being restated per domain.
    ///
    /// `kind` is `nil` for pre-approved findings (duplicates), whose card is
    /// included from the moment results land and does not track its selection.
    private func applySelection<ID: Hashable>(
        _ ids: some Sequence<ID>,
        selected: Bool,
        to storage: ReferenceWritableKeyPath<SmartScanViewModel, Set<ID>>,
        optInKind kind: CareFinding.Kind?
    ) {
        if selected {
            self[keyPath: storage].formUnion(ids)
        } else {
            self[keyPath: storage].subtract(ids)
        }
        if let kind {
            syncOptInInclusion(kind, hasSelection: !self[keyPath: storage].isEmpty)
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
        updateSelection.contains(update.id)
    }

    func toggleUpdate(_ update: UpdateInfo) {
        if updateSelection.contains(update.id) {
            updateSelection.remove(update.id)
        } else {
            updateSelection.insert(update.id)
        }
    }

    /// Check or uncheck every available update in one write.
    func setAllUpdates(selected: Bool) {
        guard case .appUpdates(let updates)? = currentPlan?.finding(.appUpdates)?.payload else { return }
        updateSelection = selected ? Set(updates.map(\.id)) : []
    }

    // MARK: - Maintenance selection

    func isMaintenanceTaskSelected(_ taskID: String) -> Bool {
        maintenanceSelection.contains(taskID)
    }

    func toggleMaintenanceTask(_ taskID: String) {
        if maintenanceSelection.contains(taskID) {
            maintenanceSelection.remove(taskID)
        } else {
            maintenanceSelection.insert(taskID)
        }
    }

    /// Check or uncheck every due maintenance task in one write.
    func setAllMaintenanceTasks(selected: Bool) {
        guard case .maintenanceDue(let taskIDs)? = currentPlan?.finding(.maintenanceDue)?.payload else { return }
        maintenanceSelection = selected ? Set(taskIDs) : []
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
        applySelection(urls, selected: selected, to: \.duplicateSelection, optInKind: nil)
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
        applySelection(urls, selected: selected, to: \.similarImageSelection, optInKind: .similarImages)
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
        applySelection(urls, selected: selected, to: \.downloadSelection, optInKind: .downloads)
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
        applySelection(urls, selected: selected, to: \.largeOldFileSelection, optInKind: .largeOldFiles)
    }

    func isUnusedAppSelected(_ app: UnusedApp) -> Bool {
        unusedAppSelection.contains(app.id)
    }

    func toggleUnusedApp(_ app: UnusedApp) {
        setUnusedApps([app.id], selected: !unusedAppSelection.contains(app.id))
    }

    func setUnusedApps(_ ids: [String], selected: Bool) {
        applySelection(ids, selected: selected, to: \.unusedAppSelection, optInKind: .unusedApps)
    }

    func isUnsupportedAppSelected(_ app: UnsupportedApp) -> Bool {
        unsupportedAppSelection.contains(app.id)
    }

    func toggleUnsupportedApp(_ app: UnsupportedApp) {
        setUnsupportedApps([app.id], selected: !unsupportedAppSelection.contains(app.id))
    }

    func setUnsupportedApps(_ ids: [String], selected: Bool) {
        applySelection(ids, selected: selected, to: \.unsupportedAppSelection, optInKind: .unsupportedApps)
    }

    func isLeftoverSelected(_ group: LeftoverGroup) -> Bool {
        leftoverSelection.contains(group.bundleID)
    }

    func toggleLeftover(_ group: LeftoverGroup) {
        setLeftovers([group.bundleID], selected: !leftoverSelection.contains(group.bundleID))
    }

    func setLeftovers(_ bundleIDs: [String], selected: Bool) {
        applySelection(bundleIDs, selected: selected, to: \.leftoverSelection, optInKind: .appLeftovers)
    }

    func isInstallerSelected(_ file: InstallationFile) -> Bool {
        installerSelection.contains(file.id)
    }

    func toggleInstaller(_ file: InstallationFile) {
        setInstallers([file.id], selected: !installerSelection.contains(file.id))
    }

    func setInstallers(_ ids: [String], selected: Bool) {
        applySelection(ids, selected: selected, to: \.installerSelection, optInKind: .installers)
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

    /// Bytes a Run would free from one finding's current selection. The feed's
    /// pre-approved tiles show this rather than the gross "found" total, so the
    /// number a user reads matches what one tap actually frees — junk seeds its
    /// selection to safe categories only, so the two differ.
    func freeableBytes(for kind: CareFinding.Kind) -> Int64 {
        selectedBytes(for: kind)
    }

    /// Selected freeable bytes across the pre-approved findings — what the
    /// hero's "can be freed safely" line reflects, so it agrees with the tiles
    /// and the disc caption instead of promising the gross total found.
    var preApprovedFreeableBytes: Int64 {
        (currentPlan?.findings ?? [])
            .filter { $0.actionability == .preApproved }
            .reduce(0) { $0 + selectedBytes(for: $1.kind) }
    }

    /// How many pre-approved findings Fix will handle — the count the hero
    /// states. Scoped to the same "handled by Fix" set as the bytes so the
    /// hero can't say "11 things" while the caption says "4 items"; the opt-in
    /// findings have their own "Worth a look" zone.
    var preApprovedCount: Int {
        (currentPlan?.findings ?? [])
            .filter { $0.actionability == .preApproved }
            .count
    }

    /// Selected bytes for one finding, mirroring the size sources `execute`
    /// uses so the caption's total matches what the receipt will report.
    private func selectedBytes(for kind: CareFinding.Kind) -> Int64 {
        guard let payload = currentPlan?.finding(kind)?.payload else { return 0 }
        switch payload {
        case .junk:
            return selectedJunkBytes
        case .duplicates(let groups):
            return selectedBytes(in: duplicateSelection, kind: kind, sizes: {
                groups.flatMap { $0.files.map { ($0.url, $0.size) } }
            })
        case .largeOldFiles(let files):
            return selectedBytes(in: largeOldFileSelection, kind: kind, sizes: {
                files.map { ($0.url, $0.size) }
            })
        case .similarImages(let groups):
            return selectedBytes(in: similarImageSelection, kind: kind, sizes: {
                groups.flatMap { $0.files.map { ($0.url, $0.size) } }
            })
        case .downloads(let items):
            return selectedBytes(in: downloadSelection, kind: kind, sizes: {
                items.map { ($0.file.url, $0.file.size) }
            })
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

    /// Sums the sizes of the selected URLs for one finding. An empty selection
    /// answers without touching the file list at all, and the (url, size)
    /// lookup is built once per plan rather than rebuilt on every read — the
    /// two together keep a feed render off the finding's whole file list, which
    /// the cards, the hero, and the disc caption each used to walk.
    private func selectedBytes(
        in selection: Set<URL>,
        kind: CareFinding.Kind,
        sizes: () -> [(URL, Int64)]
    ) -> Int64 {
        guard !selection.isEmpty else { return 0 }
        let table = sizeTable(for: kind, sizes: sizes)
        return selection.reduce(0) { $0 + (table[$1] ?? 0) }
    }

    /// The memoized url→size lookup for one finding, built on first use and
    /// held until the next plan lands.
    private func sizeTable(for kind: CareFinding.Kind, sizes: () -> [(URL, Int64)]) -> [URL: Int64] {
        if let cached = sizeTables[kind] { return cached }
        let table = Dictionary(sizes(), uniquingKeysWith: { first, _ in first })
        sizeTables[kind] = table
        return table
    }

    /// Whether the floating Run disc should be on screen: only on the
    /// results feed, only with work to do, and never while a Review, the
    /// confirmation sheet, or a post-Fix re-check is in flight.
    var isRunDiscVisible: Bool {
        guard case .results = phase else { return false }
        return hasExecutableWork && !isReviewing && !isConfirmingRun && !isRefreshingFindings
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
        // A re-check in flight means the plan is missing the findings it is
        // re-scanning; running against that would act on half a picture.
        guard case .results = phase, hasExecutableWork, !isRefreshingFindings else { return }
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
        rankedFindings
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
        // The single funnel for every Run entry point, so a re-check in flight
        // can't be acted against: the plan is missing what it's re-scanning.
        guard case .results(let plan) = phase, !isRefreshingFindings else { return }
        // The phase stops carrying the plan from here on; Done re-checks only
        // what this pass changed and hands the rest of it straight back.
        planUnderRun = plan
        // Resolve the queue up front so the running screen can show honest
        // "step N of M" progress and the current action's label.
        let queue = CarePlanRanker.ranked(plan.findings, context: severityContext)
            .filter { willExecuteDuringRun($0) }
        runProgress = RunProgress(
            completed: 0,
            total: queue.count,
            currentLabel: queue.first.map { CareFindingCopy.runProgressLabel(for: $0.kind) } ?? "",
            bytesFreed: 0
        )
        phase = .running

        var lines: [CareReceiptLine] = []
        var bytesFreed: Int64 = 0
        for (index, finding) in queue.enumerated() {
            runProgress = RunProgress(
                completed: index,
                total: queue.count,
                currentLabel: CareFindingCopy.runProgressLabel(for: finding.kind),
                bytesFreed: bytesFreed
            )
            if let line = await execute(finding) {
                lines.append(line)
                bytesFreed += line.bytesFreed
            }
        }
        let receipt = CareReceipt(date: Date(), lines: lines)
        recordReceipt(receipt)
        recordRunChoices(declinedKinds(in: plan, queue: queue), Set(queue.map(\.kind)))
        runProgress = nil
        phase = .done(receipt: receipt)
    }

    /// Actionable findings the user was shown and this pass left behind.
    ///
    /// A completed Run is the one moment a decline is unambiguous: the plan was
    /// on screen, the user chose to act, and this finding was not part of what
    /// they chose. Closing the window or never running tells us nothing, so
    /// neither is counted.
    private func declinedKinds(
        in plan: CarePlan,
        queue: [CareFinding]
    ) -> Set<CareFinding.Kind> {
        let acted = Set(queue.map(\.kind))
        return Set(
            plan.findings
                .filter { $0.actionability != .informational && !acted.contains($0.kind) }
                .map(\.kind)
        )
    }

    /// `willExecute` reads `phase == .results`; during the pass the phase is
    /// `.running`, so Run re-checks inclusion and selection directly.
    private func willExecuteDuringRun(_ finding: CareFinding) -> Bool {
        guard includedFindings.contains(finding.kind) else { return false }
        switch finding.kind {
        case .loginItems, .lowDiskSpace: return false
        default: return selectionCount(for: finding.kind) > 0
        }
    }

    private func execute(_ finding: CareFinding) async -> CareReceiptLine? {
        switch finding.payload {
        case .junk(let result):
            return await executeJunkCleanup(result)

        case .threats(let threats):
            return await executeThreatRemoval(threats)

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
            return await executeUnusedAppRemoval(apps)

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
            return await executeLeftoverRemoval(groups)

        case .appUpdates(let updates):
            return await executeAppUpdates(updates)

        case .maintenanceDue(let taskIDs):
            return await executeMaintenance(taskIDs)

        case .browserPrivacy:
            return await executeBrowserPrivacy()

        case .loginItems, .lowDiskSpace, .extensions, .backgroundItems:
            return nil
        }
    }

    // MARK: - Per-kind execution
    //
    // One method per finding kind that does more than hand a URL list to
    // `recycleLine`, so `execute(_:)` above stays a readable dispatch table.

    private func executeJunkCleanup(_ result: ScanResult) async -> CareReceiptLine? {
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
            log.error("Smart Scan junk clean failed: \(String(describing: error), privacy: .private)")
            return CareReceiptLine(kind: .junkCleanup, itemsProcessed: 0, bytesFreed: 0, outcome: .failed(message: error.localizedDescription))
        }
    }

    private func executeThreatRemoval(_ threats: [MalwareThreat]) async -> CareReceiptLine? {
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
    }

    /// Uninstalls each chosen unused app the way the Applications Manager
    /// does: the bundle **and** the support files that belong to it.
    /// Recycling the bundle alone leaves preferences, caches, and containers
    /// on disk, which the next scan then reports back as leftovers — the
    /// same app cleaned twice, and less space freed than the card promised.
    private func executeUnusedAppRemoval(_ apps: [UnusedApp]) async -> CareReceiptLine? {
        let selected = apps.filter { unusedAppSelection.contains($0.id) }
        guard !selected.isEmpty else { return nil }

        var urls: [URL] = []
        var sizeOf: [URL: Int64] = [:]
        for app in selected {
            urls.append(app.app.bundleURL)
            sizeOf[app.app.bundleURL] = app.sizeBytes
            for file in await findAssociatedFiles(app.app.bundleID) {
                urls.append(file.url)
                sizeOf[file.url] = file.sizeBytes
            }
        }

        let recycled = await recycleFiles(urls)
        // An app counts as uninstalled when its *bundle* reached the Trash.
        // A support file left behind is a stray, not a failed uninstall —
        // and a bundle that wouldn't move is a failure however many of its
        // caches did.
        let removed = selected.filter { recycled.contains($0.app.bundleURL) }
        return CareReceiptLine(
            kind: .unusedApps,
            itemsProcessed: removed.count,
            bytesFreed: recycled.reduce(Int64(0)) { $0 + (sizeOf[$1] ?? 0) },
            outcome: removed.count == selected.count
                ? .success
                : .partial(failedCount: selected.count - removed.count)
        )
    }

    private func executeLeftoverRemoval(_ groups: [LeftoverGroup]) async -> CareReceiptLine? {
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
    }

    private func executeAppUpdates(_ updates: [UpdateInfo]) async -> CareReceiptLine? {
        let selected = updates.filter { updateSelection.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        for update in selected {
            // Homebrew-managed updates carry no URL — they are applied by
            // `brew`, not opened. Smart Scan's probe never yields them,
            // but the model allows it, so skip rather than assume.
            guard let url = update.updateURL else { continue }
            await updateOpener(url)
        }
        return CareReceiptLine(kind: .appUpdates, itemsProcessed: selected.count, bytesFreed: 0, outcome: .success)
    }

    private func executeMaintenance(_ taskIDs: [String]) async -> CareReceiptLine? {
        let selected = taskIDs.filter { maintenanceSelection.contains($0) }
        guard !selected.isEmpty else { return nil }
        var completed = 0
        var lastError: String?
        for taskID in selected {
            do {
                try await maintenanceTaskRunner(taskID)
                recordMaintenanceRun(taskID)
                completed += 1
            } catch {
                log.error("Smart Scan maintenance task \(taskID, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                // Every task here runs through the privileged helper, so an
                // unreachable helper is the common failure. Mapped rather than
                // reported raw: the system text for a dropped XPC connection is
                // "Couldn't communicate with a helper application.", which names
                // nothing the user can act on.
                lastError = HelperConnectionError.userFacingMessage(for: error)
            }
        }
        let outcome: CareReceiptLine.Outcome
        if completed == selected.count {
            outcome = .success
        } else if completed > 0 {
            outcome = .partial(failedCount: selected.count - completed)
        } else {
            outcome = .failed(message: lastError ?? "")
        }
        return CareReceiptLine(kind: .maintenanceDue, itemsProcessed: completed, bytesFreed: 0, outcome: outcome)
    }

    private func executeBrowserPrivacy() async -> CareReceiptLine? {
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
            log.error("Smart Scan browser privacy clear failed: \(String(describing: error), privacy: .private)")
            return CareReceiptLine(kind: .browserPrivacy, itemsProcessed: 0, bytesFreed: 0, outcome: .failed(message: error.localizedDescription))
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

    // MARK: - Finishing a run

    /// The receipt's Done button: dismiss it and go back to the feed.
    func finishRun() {
        runScanActivity(reason: "VaderCleaner is re-checking what it cleaned") {
            await self.rescanHandledFindings()
        }
    }

    /// Leaves the receipt for the results feed — never the intro, and never a
    /// scanning screen.
    ///
    /// The feed comes back immediately, minus the findings the pass actually
    /// consumed; those are re-scanned in the background and drop back in when
    /// they land. Everything else carries forward untouched: the run never went
    /// near it, so it is still true, and re-walking the filesystem to rediscover
    /// it is what made Done cost a whole second scan.
    func rescanHandledFindings() async {
        guard case .done(let receipt) = phase else { return }
        guard let plan = planUnderRun else {
            // No plan to hand back — the intro is the only honest place to land.
            reset()
            return
        }
        // A line that processed items is work that landed, so its finding is
        // stale. A line that processed nothing changed nothing — a refused
        // tune-up, a threat that couldn't be quarantined — and its finding is
        // still true, so it stays on the feed without being re-scanned.
        let changed = Set(receipt.lines.filter { $0.itemsProcessed > 0 }.map(\.kind.unit))
        guard !changed.isEmpty else {
            phase = .results(plan)
            planUnderRun = nil
            return
        }
        // Health rides along because a cleanup changes free space, which is the
        // number the verdict hero reads. The gates in Customize Smart Care
        // aren't re-applied: this re-checks work just done, it isn't a new scan.
        let units = changed.union([.healthSnapshot])

        scanGeneration += 1
        let generation = scanGeneration
        // Back to the feed at once, without the cards the pass consumed — their
        // counts describe deleted files. Their selections go too, or the footer
        // and hero totals would keep counting what is gone.
        for kind in plan.findings.map(\.kind) where units.contains(kind.unit) {
            clearSelection(for: kind)
        }
        invalidateResultsCaches()
        planUnderRun = nil
        isRefreshingFindings = true
        phase = .results(plan.removingFindings(for: units))
        // The junk tree is the largest thing the app holds and the run just
        // deleted part of it, so drop it now instead of keeping a stale copy
        // alive across the re-scan; `land` reloads from the merged plan.
        if units.contains(.systemJunk) {
            junkManagerStore.unload()
        }

        let configuration = CareScanEngine.Configuration(
            enabledUnits: units,
            enabledJunkCategories: enabledJunkCategories(),
            malwareEngineAvailable: malwareEngineAvailable()
        )
        // No event handling: the feed shows no per-unit progress, and the
        // checklist isn't on screen to fill in.
        let refreshed = await scanEngine(configuration) { _ in }
        isRefreshingFindings = false
        // Merge only into the feed the user is still on — a fresh scan, Start
        // Over, or a reset supersedes this re-check.
        guard generation == scanGeneration, case .results = phase else { return }
        // Only the re-checked units may re-seed: everything else on the merged
        // plan is the finding the user was already looking at, with whatever
        // they decided about it still standing.
        await land(plan.merging(refreshed, for: units), stampHistory: false, seeding: units)
    }

    /// Where each finding keyed by file URL keeps its selection, so clearing one
    /// doesn't cost a branch per kind. The informational kinds are absent
    /// because they carry no selection at all.
    private static let fileSelectionPaths: [CareFinding.Kind: ReferenceWritableKeyPath<SmartScanViewModel, Set<URL>>] = [
        .junkCleanup: \.junkFileSelection,
        .threats: \.threatSelection,
        .duplicates: \.duplicateSelection,
        .similarImages: \.similarImageSelection,
        .downloads: \.downloadSelection,
        .largeOldFiles: \.largeOldFileSelection,
    ]

    /// The same table for findings whose items are identified by a stable id
    /// (bundle id, task id, group id) rather than a file URL.
    private static let identifierSelectionPaths: [CareFinding.Kind: ReferenceWritableKeyPath<SmartScanViewModel, Set<String>>] = [
        .appUpdates: \.updateSelection,
        .maintenanceDue: \.maintenanceSelection,
        .unusedApps: \.unusedAppSelection,
        .appLeftovers: \.leftoverSelection,
        .installers: \.installerSelection,
        .unsupportedApps: \.unsupportedAppSelection,
    ]

    /// Clears one finding's selection, used when a Run pass has consumed it: the
    /// selection names items that are gone, and every total derived from it
    /// (zone footers, the disc caption, the hero) would keep counting them.
    private func clearSelection(for kind: CareFinding.Kind) {
        if let path = Self.fileSelectionPaths[kind] {
            self[keyPath: path] = []
        }
        if let path = Self.identifierSelectionPaths[kind] {
            self[keyPath: path] = []
        }
        if kind == .browserPrivacy {
            browserPrivacySelection = []
        }
        if kind == .junkCleanup {
            // Derived tallies kept beside the junk selection for O(1) reads.
            selectedJunkBytes = 0
            selectedJunkBytesByCategory = [:]
            selectedJunkCountByCategory = [:]
        }
        includedFindings.remove(kind)
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
        declines: CareDeclineStore? = nil,
        protectionSettings: ProtectionSettingsStore? = nil
    ) -> SmartScanViewModel {
        // Default arguments evaluate outside the main actor, so the fallback
        // stores (previews, tests) are built here instead.
        let history = history ?? CareHistoryStore()
        let declines = declines ?? CareDeclineStore()
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

        return SmartScanViewModel(
            scanEngine: { configuration, onEvent in
                await engine.scan(configuration: configuration, onEvent: onEvent)
            },
            junkCleaner: { try await SystemJunkDeleter().delete($0) },
            threatRemover: { await threatRemover.remove($0) },
            updateOpener: { url in
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            },
            recycleFiles: { urls in await UserFileRecycler.recycle(urls, context: "Smart Scan") },
            // The Uninstaller's own lookup, exclusions read per app so a
            // freshly-added Ignore List entry is honoured on the next run.
            findAssociatedFiles: { [weak exclusions] bundleID in
                let excluded = await MainActor.run {
                    (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                }
                return await DefaultAssociatedFileFinder(excluding: excluded).find(forBundleID: bundleID)
            },
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
            recordReceipt: { history.recordReceipt($0) },
            pastReceipts: { history.receipts },
            declineCounts: { declines.counts },
            recordRunChoices: { declines.record(declined: $0, accepted: $1) }
        )
    }

    /// Default recycler: move each file to the user's Trash via
    /// `NSWorkspace.recycle` (restorable) and return the URLs that actually
    /// moved. Marked `nonisolated` so a multi-gigabyte batch runs off the
    /// main actor. Failures are logged with hash-masked privacy.
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
