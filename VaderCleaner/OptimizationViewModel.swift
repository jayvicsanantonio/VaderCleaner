// OptimizationViewModel.swift
// State machine behind the Optimization view — loads login items + launch agents + RAM, and drives RAM flush, maintenance scripts, login-item toggle, and agent disable/remove through injected collaborators.

import Combine
import Foundation
import Observation
import os.log

/// Drives the Optimization feature view. Collaborators are injected as
/// closures so unit tests can exercise every transition without touching
/// real login-item / launchd / privileged-helper state. Production wiring
/// lives in `OptimizationViewModel.live()`.
@MainActor
@Observable
final class OptimizationViewModel {

    /// Discrete phases the view binds to. `working` covers any one-shot
    /// action (flush, maintenance, toggle, disable, remove); `failed` carries
    /// the message to surface.
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case working
        case failed(message: String)
    }

    typealias LoadLoginItems = () async -> [LoginItem]
    typealias LoadAgents = () async -> [LaunchAgent]
    typealias ReadMemory = @MainActor () -> MemoryStats
    typealias SetLoginItemEnabled = (Bool, LoginItem) async throws -> Void
    typealias DisableAgent = (LaunchAgent) async throws -> Void
    typealias EnableAgent = (LaunchAgent) async throws -> Void
    typealias RemoveAgent = (LaunchAgent) async throws -> Void
    typealias FlushRAM = () async throws -> Void
    typealias RunMaintenance = () async throws -> String
    /// A maintenance task that performs its work and returns a result line.
    typealias RunTask = () async throws -> String
    typealias ReadSnapshotCount = () async -> Int

    private(set) var phase: Phase = .idle
    private(set) var loginItems: [LoginItem] = []
    private(set) var userAgents: [LaunchAgent] = []
    private(set) var systemAgents: [LaunchAgent] = []
    private(set) var memory: MemoryStats = .empty
    private(set) var ramResult: String?
    private(set) var maintenanceOutput: String?

    /// Count of local Time Machine snapshots, refreshed alongside the rest of
    /// the section state and fed into the recommendation engine.
    private(set) var localSnapshotCount: Int = 0
    /// Curated dashboard cards derived from the current system state.
    private(set) var recommendations: [PerformanceRecommendation] = []
    /// Most recent result line per task id, surfaced in the task catalog.
    private(set) var taskResults: [String: String] = [:]

    /// Human-readable title of the action currently running, so the progress
    /// screen can name it ("Free Up RAM…") instead of a bare spinner.
    private(set) var workingTitle: String?

    /// True while a multi-task batch ("Run Tasks" / catalog multi-select) is in
    /// flight. The view holds the progress screen for the whole batch so it
    /// doesn't flicker between progress and the catalog as each task's phase
    /// flips `.working`→`.ready`.
    private(set) var isRunningBatch = false
    /// Recommendation kinds whose action completed successfully, so the matching
    /// dashboard tile can show a green check. Cleared on the next refresh, or
    /// when that tile's action is run again.
    private(set) var completedRecommendations: Set<PerformanceRecommendation.Kind> = []

    /// Set when the current failure is specifically a missing Full Disk Access
    /// (Speed Up Mail), so the failure screen can offer an "Open Settings"
    /// recovery instead of a dead end.
    private(set) var failureNeedsFullDiskAccess = false

    /// The maintenance-task catalog shown in "View All Tasks", with tasks that
    /// can't run on this system filtered out — Run Maintenance Scripts relies on
    /// `/usr/sbin/periodic`, which Apple removed in macOS 26.
    var tasks: [MaintenanceTask] {
        MaintenanceTask.catalog.filter { task in
            task.kind != .runMaintenanceScripts || maintenanceScriptsAvailable
        }
    }

    /// Cocktail task ids that are actually available, for the recommendation
    /// count and the "Run Tasks" action.
    private var availableCocktailIDs: [String] {
        tasks
            .filter { MaintenanceTask.maintenanceCocktailKinds.contains($0.kind) }
            .map(\.id)
    }

    @ObservationIgnored private let loadLoginItems: LoadLoginItems
    @ObservationIgnored private let loadUserAgents: LoadAgents
    @ObservationIgnored private let loadSystemAgents: LoadAgents
    @ObservationIgnored private let readMemory: ReadMemory
    @ObservationIgnored private let setLoginItemEnabled: SetLoginItemEnabled
    @ObservationIgnored private let disableAgent: DisableAgent
    @ObservationIgnored private let enableAgent: EnableAgent
    @ObservationIgnored private let removeAgent: RemoveAgent
    @ObservationIgnored private let flushRAMAction: FlushRAM
    @ObservationIgnored private let runMaintenance: RunMaintenance
    @ObservationIgnored private let flushDNSAction: RunTask
    @ObservationIgnored private let reindexSpotlightAction: RunTask
    @ObservationIgnored private let thinSnapshotsAction: RunTask
    @ObservationIgnored private let speedUpMailAction: RunTask
    @ObservationIgnored private let readSnapshotCount: ReadSnapshotCount
    @ObservationIgnored private let runLog: MaintenanceRunLog
    /// Whether `/usr/sbin/periodic` exists — false on macOS 26+, where Apple
    /// removed it, so Run Maintenance Scripts is hidden and never run.
    @ObservationIgnored private let maintenanceScriptsAvailable: Bool

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "OptimizationViewModel")

    /// Monotonic token so a stale load resolving after a newer `refresh()`
    /// can't clobber fresh state — same pattern as the other feature
    /// view-models.
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init(
        loadLoginItems: @escaping LoadLoginItems,
        loadUserAgents: @escaping LoadAgents,
        loadSystemAgents: @escaping LoadAgents,
        readMemory: @escaping ReadMemory,
        setLoginItemEnabled: @escaping SetLoginItemEnabled,
        disableAgent: @escaping DisableAgent,
        enableAgent: @escaping EnableAgent,
        removeAgent: @escaping RemoveAgent,
        flushRAM: @escaping FlushRAM,
        runMaintenance: @escaping RunMaintenance,
        flushDNS: @escaping RunTask = { "" },
        reindexSpotlight: @escaping RunTask = { "" },
        thinSnapshots: @escaping RunTask = { "" },
        speedUpMail: @escaping RunTask = { "" },
        readSnapshotCount: @escaping ReadSnapshotCount = { 0 },
        runLog: MaintenanceRunLog = MaintenanceRunLog(),
        maintenanceScriptsAvailable: Bool = true,
        launchAtLoginChanges: AnyPublisher<Void, Never>? = nil
    ) {
        self.loadLoginItems = loadLoginItems
        self.loadUserAgents = loadUserAgents
        self.loadSystemAgents = loadSystemAgents
        self.readMemory = readMemory
        self.setLoginItemEnabled = setLoginItemEnabled
        self.disableAgent = disableAgent
        self.enableAgent = enableAgent
        self.removeAgent = removeAgent
        self.flushRAMAction = flushRAM
        self.runMaintenance = runMaintenance
        self.flushDNSAction = flushDNS
        self.reindexSpotlightAction = reindexSpotlight
        self.thinSnapshotsAction = thinSnapshots
        self.speedUpMailAction = speedUpMail
        self.readSnapshotCount = readSnapshotCount
        self.runLog = runLog
        self.maintenanceScriptsAvailable = maintenanceScriptsAvailable

        // The host app's launch-at-login state has a second entry point:
        // the Preferences "Launch at Login" toggle, which mutates
        // `PreferencesStore.launchAtLogin`. When it changes from there,
        // reload our row so the two surfaces never disagree in-session
        // (issue #65). The `.receive(on:)` hop is load-bearing, not
        // cosmetic: `@Published` fires its publisher in `willSet`, before
        // `PreferencesStore`'s `didSet` has applied the change to
        // `SMAppService`. Re-reading the live login-item status
        // synchronously here would observe the *old* status; deferring to
        // the next runloop pass guarantees the reload runs after `didSet`.
        if let launchAtLoginChanges {
            launchAtLoginChanges
                .receive(on: RunLoop.main)
                .sink { [weak self] in
                    guard let self else { return }
                    Task { await self.reloadLoginItemsAfterExternalChange() }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Loading

    /// Loads all four sections concurrently and lands `.ready`. Discovery is
    /// best-effort (missing directories degrade to empty lists), so there is
    /// no load-failure path — action failures are what surface `.failed`.
    func refresh() async {
        let generation = beginLoad()
        phase = .loading

        async let login = loadLoginItems()
        async let user = loadUserAgents()
        async let system = loadSystemAgents()
        async let snapshots = readSnapshotCount()
        let (loadedLogin, loadedUser, loadedSystem, loadedSnapshots) =
            await (login, user, system, snapshots)
        let mem = readMemory()

        guard loadGeneration == generation else { return }
        loginItems = loadedLogin
        userAgents = loadedUser
        systemAgents = loadedSystem
        memory = mem
        localSnapshotCount = loadedSnapshots
        completedRecommendations.removeAll()
        rebuildRecommendations()
        phase = .ready
    }

    // MARK: - Recommendations

    /// Runs the action behind a dashboard recommendation tile and, on success,
    /// marks that tile complete so the view can show a green check on it. The
    /// background-items tile only navigates (handled by the view), so it never
    /// reaches here.
    func runRecommendation(_ recommendation: PerformanceRecommendation) async {
        completedRecommendations.remove(recommendation.kind)
        switch recommendation.kind {
        case .freeUpRAM:
            if let task = MaintenanceTask.catalog.first(where: { $0.kind == .freeUpRAM }) {
                await run(task)
            }
        case .maintenanceTasks:
            await runDueMaintenance()
        case .thinSnapshots:
            if let task = MaintenanceTask.catalog.first(where: { $0.kind == .thinTimeMachineSnapshots }) {
                await run(task)
            }
        case .backgroundItems:
            return
        }
        if phase == .ready {
            completedRecommendations.insert(recommendation.kind)
        }
    }

    // MARK: - Maintenance tasks

    /// Runs a catalog task. Free up RAM and the maintenance scripts route
    /// through their existing methods (which keep their own result lines and
    /// memory re-read); the newer system tasks run through the shared `perform`
    /// path. On success the task is stamped in the run log and the
    /// recommendation cards are rebuilt.
    func run(_ task: MaintenanceTask) async {
        // Name the running action for the progress screen, and clear any prior
        // FDA-recovery flag so it only reflects this run's outcome.
        workingTitle = task.title
        failureNeedsFullDiskAccess = false
        switch task.kind {
        case .freeUpRAM:
            await flushRAM()
            finishTask(task.kind, result: ramResult)
        case .runMaintenanceScripts:
            await runMaintenanceScripts()
            finishTask(task.kind, result: maintenanceOutput)
        case .flushDNS:
            await perform(task.kind, action: flushDNSAction)
        case .reindexSpotlight:
            await perform(task.kind, action: reindexSpotlightAction)
        case .thinTimeMachineSnapshots:
            await perform(task.kind, action: thinSnapshotsAction)
        case .speedUpMail:
            await perform(task.kind, action: speedUpMailAction)
        }
        workingTitle = nil
    }

    /// Shared run path for the system maintenance tasks: drive `.working`, run
    /// the action, capture its result line, stamp the run log, and rebuild
    /// recommendations. Surfaces `.failed` on any error.
    private func perform(_ kind: MaintenanceTask.Kind, action: RunTask) async {
        phase = .working
        do {
            let result = try await action()
            taskResults[kind.rawValue] = result
            runLog.record(kind.rawValue)
            localSnapshotCount = await readSnapshotCount()
            rebuildRecommendations()
            phase = .ready
        } catch {
            log.error("Maintenance task \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if case MailReindexerError.fullDiskAccessRequired = error {
                failureNeedsFullDiskAccess = true
            }
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Post-success bookkeeping for the tasks that route through their existing
    /// methods. Skips when the underlying method left a non-ready phase (e.g. a
    /// flush failure already surfaced `.failed`).
    private func finishTask(_ kind: MaintenanceTask.Kind, result: String?) {
        guard phase == .ready else { return }
        if let result {
            taskResults[kind.rawValue] = result
        }
        runLog.record(kind.rawValue)
        rebuildRecommendations()
    }

    /// Runs the given tasks in order — the action behind the catalog's
    /// multi-select "Run" bar. Stops at the first failure, which surfaces
    /// `.failed` so the user sees what went wrong.
    func run(_ tasks: [MaintenanceTask]) async {
        // Hold the progress screen for the whole batch so the UI doesn't flicker
        // as each task's phase flips between .working and .ready.
        isRunningBatch = true
        defer { isRunningBatch = false }
        for task in tasks {
            await run(task)
            if case .failed = phase { return }
        }
    }

    /// Runs every due maintenance-cocktail task (the action behind the
    /// "Maintenance Tasks Recommended" card), so the card's count and its "Run
    /// Tasks" action cover the same set.
    func runDueMaintenance() async {
        let dueIDs = runLog.staleTaskIDs(among: availableCocktailIDs)
        let dueTasks = tasks.filter { dueIDs.contains($0.id) }
        await run(dueTasks)
    }

    /// Recomputes the curated recommendation cards from current section state.
    /// The maintenance count is scoped to the cocktail tasks so it matches what
    /// `runDueMaintenance()` actually runs.
    private func rebuildRecommendations() {
        let snapshot = PerformanceSnapshot(
            memory: memory,
            localSnapshotCount: localSnapshotCount,
            backgroundItemCount: loginItems.count + userAgents.count + systemAgents.count,
            staleTaskCount: runLog.staleTaskCount(among: availableCocktailIDs)
        )
        recommendations = PerformanceRecommendationEngine.recommendations(for: snapshot)
    }

    // MARK: - RAM

    /// Flushes inactive memory through the privileged helper, then re-reads
    /// usage so the displayed figure and the result line reflect the post-
    /// flush state.
    func flushRAM() async {
        phase = .working
        do {
            try await flushRAMAction()
            memory = readMemory()
            let format = String(
                localized: "Freed inactive memory. Memory in use: %@.",
                comment: "Result line after a successful RAM flush; %@ is a used/total memory string."
            )
            ramResult = String.localizedStringWithFormat(
                format, SystemStatsFormatters.memoryUsageString(memory)
            )
            phase = .ready
        } catch {
            log.error("RAM flush failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    // MARK: - Maintenance

    /// Runs the system maintenance scripts through the privileged helper and
    /// stores the result line for the view's output log.
    func runMaintenanceScripts() async {
        phase = .working
        do {
            maintenanceOutput = try await runMaintenance()
            phase = .ready
        } catch {
            log.error("Maintenance scripts failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    // MARK: - Login items

    /// Enables or disables a login item, then reloads the list so the row
    /// reflects the new `SMAppService` status.
    func setLoginItem(_ item: LoginItem, enabled: Bool) async {
        phase = .working
        do {
            try await setLoginItemEnabled(enabled, item)
            loginItems = await loadLoginItems()
            phase = .ready
        } catch {
            log.error("Login-item toggle failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Reloads only the login-items row after the launch-at-login
    /// preference was changed elsewhere (the Preferences toggle). Unlike
    /// `refresh()` this does not touch `phase` — it is a background
    /// reconciliation, not a user-initiated load — and is gated on
    /// `loadGeneration` so a stale reload can't clobber a fresh
    /// `refresh()` that started while this was in flight.
    private func reloadLoginItemsAfterExternalChange() async {
        let generation = loadGeneration
        let reloaded = await loadLoginItems()
        guard loadGeneration == generation else { return }
        loginItems = reloaded
    }

    // MARK: - Launch agents

    /// Loads an agent into launchd. Only user agents have a toggle, so the
    /// row updates in place via `setLoaded` rather than reloading the section.
    func enable(_ agent: LaunchAgent) async {
        await setLoaded(agent, to: true, via: enableAgent)
    }

    /// Unloads an agent from launchd. Only user agents have a toggle, so the
    /// row updates in place via `setLoaded` rather than reloading the section.
    func disable(_ agent: LaunchAgent) async {
        await setLoaded(agent, to: false, via: disableAgent)
    }

    /// Toggles a user agent's loaded state with an optimistic, in-place update:
    /// the switch flips immediately and neither a progress screen nor a list
    /// reload disturbs the rest of the section, so only the affected row
    /// animates. If the launchctl call can't even be spawned the action throws
    /// and the row is restored to its prior state.
    private func setLoaded(
        _ agent: LaunchAgent,
        to enabled: Bool,
        via action: (LaunchAgent) async throws -> Void
    ) async {
        guard let index = userAgents.firstIndex(where: { $0.id == agent.id }) else { return }
        let original = userAgents[index]
        userAgents[index] = original.settingEnabled(enabled)
        do {
            try await action(agent)
        } catch {
            // Re-find by id: a refresh() may have replaced the array while the
            // launchctl call was in flight.
            if let current = userAgents.firstIndex(where: { $0.id == agent.id }) {
                userAgents[current] = original
            }
            log.error("Agent loaded-state change failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Removes an agent's plist. On success the row is dropped; on failure
    /// the lists are left intact so the user can retry.
    ///
    /// System daemons are protected: they live in launchd's privileged domain
    /// and removing one can break macOS or the app that installed it, so the
    /// request is refused here regardless of how it was triggered. The UI also
    /// hides the control for system agents — this guard is the backstop.
    func remove(_ agent: LaunchAgent) async {
        guard agent.domain != .system else {
            log.error("Refused to remove protected system daemon: \(agent.label, privacy: .public)")
            return
        }
        phase = .working
        do {
            try await removeAgent(agent)
            userAgents.removeAll { $0.id == agent.id }
            systemAgents.removeAll { $0.id == agent.id }
            phase = .ready
        } catch {
            log.error("Agent removal failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Returns the VM to `.ready` after a `.failed` phase so the user can
    /// retry without re-running discovery.
    func dismissResult() {
        phase = .ready
    }

    // MARK: - Generations

    private func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }
}

// MARK: - Production wiring

extension OptimizationViewModel {

    /// Builds a view-model wired to the real login-item / launch-agent /
    /// RAM / maintenance collaborators. Discovery runs off the main actor so
    /// the filesystem walk and `launchctl list` don't block the UI. RAM
    /// figures are read from the shared `SystemStatsService` so the
    /// Optimization view and the Health Monitor never disagree.
    @MainActor
    static func live(
        systemStats: SystemStatsService,
        preferences: PreferencesStore
    ) -> OptimizationViewModel {
        let loginManager = LoginItemsManager.live()
        let agentManager = LaunchAgentManager()
        let ram = RAMManager()
        let maintenance = MaintenanceScriptRunner()
        let dnsFlusher = DNSCacheFlusher()
        let spotlight = SpotlightReindexer()
        let snapshotThinner = TimeMachineSnapshotThinner()
        let mail = MailReindexer()
        let snapshotCounter = LocalSnapshotCounter()

        return OptimizationViewModel(
            loadLoginItems: { loginManager.items() },
            loadUserAgents: {
                await Task.detached(priority: .userInitiated) {
                    agentManager.userAgents()
                }.value
            },
            loadSystemAgents: {
                await Task.detached(priority: .userInitiated) {
                    agentManager.systemAgents()
                }.value
            },
            // Force a synchronous re-read rather than returning the last
            // polled value: after a `purge` the 2 s poll would otherwise
            // report pre-flush usage until the next tick.
            readMemory: {
                systemStats.refresh()
                return systemStats.ramUsage
            },
            // The host app is the only login item this section manages,
            // and it is the very thing the Preferences "Launch at Login"
            // toggle controls. Route the write through `PreferencesStore`
            // rather than calling `LoginItemManager` again here, so there
            // is exactly one path that touches SMAppService, persists the
            // preference, and reports failures (issue #65). The reload
            // after this closure returns then reflects the new state, and
            // the Preferences toggle — bound to the same published value —
            // updates in lockstep.
            setLoginItemEnabled: { enabled, _ in
                preferences.launchAtLogin = enabled
            },
            disableAgent: { agent in
                try await Task.detached(priority: .userInitiated) {
                    try agentManager.disable(agent)
                }.value
            },
            enableAgent: { agent in
                try await Task.detached(priority: .userInitiated) {
                    try agentManager.enable(agent)
                }.value
            },
            removeAgent: { try await agentManager.remove($0) },
            flushRAM: { try await ram.flush() },
            runMaintenance: { try await maintenance.run() },
            flushDNS: { try await dnsFlusher.run() },
            reindexSpotlight: { try await spotlight.run() },
            thinSnapshots: { try await snapshotThinner.run() },
            speedUpMail: { try await mail.run() },
            // Listing snapshots shells out to `tmutil`; keep it off the main
            // actor so the dashboard refresh never blocks on the process.
            readSnapshotCount: {
                await Task.detached(priority: .userInitiated) {
                    snapshotCounter.count()
                }.value
            },
            // `periodic` was removed in macOS 26; when it's absent, Run
            // Maintenance Scripts is hidden and excluded from "Run Tasks".
            maintenanceScriptsAvailable: FileManager.default.fileExists(atPath: "/usr/sbin/periodic"),
            // Reflect a Preferences-side toggle in this view's row. See
            // the `init` comment for why ordering matters here. The bridge
            // converts `PreferencesStore`'s Observation-tracked property
            // into the `AnyPublisher` shape the view-model already consumes,
            // so the test surface (mockable PassthroughSubject) stays intact.
            launchAtLoginChanges: launchAtLoginChangePublisher(for: preferences)
        )
    }

    /// Bridges `PreferencesStore.launchAtLogin` (an Observation-tracked
    /// property) into an `AnyPublisher<Void, Never>` so callers built around
    /// the older Combine seam keep working unchanged. Each detected change
    /// hops back to the main actor before re-arming the registration —
    /// `withObservationTracking`'s `onChange` fires exactly once per
    /// registration, so the closure that wants a continuous stream must
    /// re-register itself after every emission. Exposed `internal` so the
    /// integration test in `OptimizationViewModelTests` can wire up the
    /// same bridge `live()` builds and pin the willSet/didSet ordering.
    @MainActor
    static func launchAtLoginChangePublisher(
        for preferences: PreferencesStore
    ) -> AnyPublisher<Void, Never> {
        let subject = PassthroughSubject<Void, Never>()
        func arm() {
            withObservationTracking {
                _ = preferences.launchAtLogin
            } onChange: {
                Task { @MainActor in
                    subject.send(())
                    arm()
                }
            }
        }
        arm()
        return subject.eraseToAnyPublisher()
    }
}

// MARK: - ScanCoordinating

extension OptimizationViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. Optimization has no idle-triggered scan — `.ready` is the
    /// loaded review surface and `.working`/`.failed` are action outcomes —
    /// so all three collapse to `.results`, the section's own detail UI.
    var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .loading:
            return .working
        case .ready, .working, .failed:
            return .results
        }
    }

    func beginScan() {
        // Semantic stretch: Optimization has no scan. "Scan" here means
        // "load" — the same `refresh()` the view runs on appear, which
        // populates login items / agents / memory and drives
        // `.idle → .loading → .ready`.
        //
        // `refresh()`'s generation token prevents stale writes but not
        // redundant work, so skip kicking off another load while one (or
        // an action in `.working`) is already in flight.
        guard phase != .loading, phase != .working else { return }
        Task { await refresh() }
    }
}
