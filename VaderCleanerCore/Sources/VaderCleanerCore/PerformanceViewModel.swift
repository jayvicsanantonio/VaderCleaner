// PerformanceViewModel.swift
// State machine behind the Performance view — loads login items + launch agents, and drives RAM flush, maintenance scripts, login-item toggle, and agent enable/disable/remove through injected collaborators.

import Foundation
import Observation
import ServiceManagement
import os.log

/// Drives the Performance feature view. Collaborators are injected as
/// closures so unit tests can exercise every transition without touching
/// real login-item / launchd / privileged-helper state. Production wiring
/// lives in `PerformanceViewModel.live()`.
@MainActor
@Observable
public final class PerformanceViewModel {

    /// Discrete phases the view binds to. `working` covers any one-shot
    /// action (flush, maintenance, toggle, disable, remove); `failed` carries
    /// the message to surface.
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case working
        case failed(message: String)
    }

    public typealias LoadLoginItems = @Sendable () async -> [LoginItem]
    public typealias LoadAgents = @Sendable () async -> [LaunchAgent]
    public typealias ReadMemory = @MainActor () -> MemoryStats
    public typealias SetLoginItemEnabled = @Sendable (Bool, LoginItem) async throws -> Void
    /// Opens System Settings to the Login Items pane, so a row pending the
    /// user's approval can deep-link there instead of asking them to navigate.
    public typealias OpenLoginItemsSettings = @MainActor () -> Void
    public typealias DisableAgent = @Sendable (LaunchAgent) async throws -> Void
    public typealias EnableAgent = @Sendable (LaunchAgent) async throws -> Void
    public typealias RemoveAgent = @Sendable (LaunchAgent) async throws -> Void
    public typealias FlushRAM = @Sendable () async throws -> Void
    public typealias RunMaintenance = @Sendable () async throws -> String
    /// A maintenance task that performs its work and returns a result line.
    public typealias RunTask = @Sendable () async throws -> String

    public private(set) var phase: Phase = .idle
    public private(set) var loginItems: [LoginItem] = []
    public private(set) var userAgents: [LaunchAgent] = []
    public private(set) var systemAgents: [LaunchAgent] = []
    private(set) var memory: MemoryStats = .empty
    private(set) var ramResult: String?
    private(set) var maintenanceOutput: String?

    /// Most recent result line per task id, surfaced in the task catalog.
    public private(set) var taskResults: [String: String] = [:]

    /// Human-readable title of the action currently running, so the progress
    /// screen can name it ("Free Up RAM…") instead of a bare spinner.
    public private(set) var workingTitle: String?

    /// True while a multi-task batch ("Run Tasks" / catalog multi-select) is in
    /// flight. The view holds the progress screen for the whole batch so it
    /// doesn't flicker between progress and the catalog as each task's phase
    /// flips `.working`→`.ready`.
    public private(set) var isRunningBatch = false

    /// Set when the current failure is specifically a missing Full Disk Access
    /// (Speed Up Mail), so the failure screen can offer an "Open Settings"
    /// recovery instead of a dead end.
    public private(set) var failureNeedsFullDiskAccess = false

    /// The maintenance-task catalog shown in "View All Tasks", with tasks that
    /// can't run on this system filtered out — Run Maintenance Scripts relies on
    /// `/usr/sbin/periodic`, which Apple removed in macOS 26.
    public var tasks: [MaintenanceTask] {
        MaintenanceTask.catalog.filter { task in
            task.kind != .runMaintenanceScripts || maintenanceScriptsAvailable
        }
    }

    /// Cocktail task ids that are actually available, for the dashboard's
    /// Maintenance card and the tasks its Review preselects.
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
    @ObservationIgnored private let openLoginItemsSettingsAction: OpenLoginItemsSettings
    @ObservationIgnored private let disableAgent: DisableAgent
    @ObservationIgnored private let enableAgent: EnableAgent
    @ObservationIgnored private let removeAgent: RemoveAgent
    @ObservationIgnored private let flushRAMAction: FlushRAM
    @ObservationIgnored private let runMaintenance: RunMaintenance
    @ObservationIgnored private let flushDNSAction: RunTask
    @ObservationIgnored private let reindexSpotlightAction: RunTask
    @ObservationIgnored private let thinSnapshotsAction: RunTask
    @ObservationIgnored private let speedUpMailAction: RunTask
    @ObservationIgnored private let runLog: MaintenanceRunLog
    /// Whether `/usr/sbin/periodic` exists — false on macOS 26+, where Apple
    /// removed it, so Run Maintenance Scripts is hidden and never run.
    @ObservationIgnored private let maintenanceScriptsAvailable: Bool

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "PerformanceViewModel")

    /// Monotonic token so a stale load resolving after a newer `refresh()`
    /// can't clobber fresh state — same pattern as the other feature
    /// view-models.
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private var launchAtLoginObserverTask: Task<Void, Never>?

    public init(
        loadLoginItems: @escaping LoadLoginItems,
        loadUserAgents: @escaping LoadAgents,
        loadSystemAgents: @escaping LoadAgents,
        readMemory: @escaping ReadMemory,
        setLoginItemEnabled: @escaping SetLoginItemEnabled,
        openLoginItemsSettings: @escaping OpenLoginItemsSettings = {},
        disableAgent: @escaping DisableAgent,
        enableAgent: @escaping EnableAgent,
        removeAgent: @escaping RemoveAgent,
        flushRAM: @escaping FlushRAM,
        runMaintenance: @escaping RunMaintenance,
        flushDNS: @escaping RunTask = { "" },
        reindexSpotlight: @escaping RunTask = { "" },
        thinSnapshots: @escaping RunTask = { "" },
        speedUpMail: @escaping RunTask = { "" },
        runLog: MaintenanceRunLog = MaintenanceRunLog(),
        maintenanceScriptsAvailable: Bool = true,
        launchAtLoginChanges: AsyncStream<Void>? = nil
    ) {
        self.loadLoginItems = loadLoginItems
        self.loadUserAgents = loadUserAgents
        self.loadSystemAgents = loadSystemAgents
        self.readMemory = readMemory
        self.setLoginItemEnabled = setLoginItemEnabled
        self.openLoginItemsSettingsAction = openLoginItemsSettings
        self.disableAgent = disableAgent
        self.enableAgent = enableAgent
        self.removeAgent = removeAgent
        self.flushRAMAction = flushRAM
        self.runMaintenance = runMaintenance
        self.flushDNSAction = flushDNS
        self.reindexSpotlightAction = reindexSpotlight
        self.thinSnapshotsAction = thinSnapshots
        self.speedUpMailAction = speedUpMail
        self.runLog = runLog
        self.maintenanceScriptsAvailable = maintenanceScriptsAvailable

        // The host app's launch-at-login state has a second entry point:
        // the Preferences "Launch at Login" toggle, which mutates
        // `PreferencesStore.launchAtLogin`. When it changes from there,
        // reload our row so the two surfaces never disagree in-session
        // (issue #65). The hop to a fresh `Task` per element is load-bearing,
        // not cosmetic: `withObservationTracking`'s `onChange` fires
        // synchronously in `willSet`, before `PreferencesStore` has even
        // queued the change for `SMAppService`, which it then applies off the
        // main actor. Re-reading the live login-item status any earlier would
        // observe the *old* status — `launchAtLoginChanges(for:)` defers its
        // yield until that write has landed, so consuming the stream here
        // just needs to await each element in turn.
        if let launchAtLoginChanges {
            launchAtLoginObserverTask = Task { [weak self] in
                for await _ in launchAtLoginChanges {
                    guard let self else { return }
                    await self.reloadLoginItemsAfterExternalChange()
                }
            }
        }
    }

    // MARK: - Loading

    /// Loads all three lists concurrently and lands `.ready`. Discovery is
    /// best-effort (missing directories degrade to empty lists), so there is
    /// no load-failure path — action failures are what surface `.failed`.
    public func refresh() async {
        let generation = beginLoad()
        phase = .loading
        await reloadLists(generation: generation)
        guard loadGeneration == generation else { return }
        phase = .ready
    }

    /// Re-reads the lists without leaving `.ready`, so an app uninstalled or an
    /// agent installed since the last look shows up without the screen flipping
    /// to a spinner or the manager losing its place. Does nothing before the
    /// first load or while an action runs: the action reloads when it finishes.
    public func reloadInBackground() async {
        guard phase == .ready, !isRunningBatch else { return }
        expireOldResults()
        await reloadLists(generation: beginLoad())
    }

    /// Fetches the three lists and applies them unless a newer load or an action
    /// has started since, whose state a slower read must not overwrite.
    private func reloadLists(generation: Int) async {
        async let login = loadLoginItems()
        async let user = loadUserAgents()
        async let system = loadSystemAgents()
        let (loadedLogin, loadedUser, loadedSystem) = await (login, user, system)

        guard loadGeneration == generation else { return }
        loginItems = loadedLogin
        userAgents = loadedUser
        systemAgents = loadedSystem
    }

    /// Drops result lines old enough that their task has come due again, so a
    /// green check doesn't claim last month's run is still news.
    private func expireOldResults() {
        for id in runLog.staleTaskIDs(among: Array(taskResults.keys)) {
            taskResults[id] = nil
        }
    }

    // MARK: - Maintenance tasks

    /// Runs a catalog task. Free up RAM and the maintenance scripts route
    /// through their existing methods (which keep their own result lines and
    /// memory re-read); the newer system tasks run through the shared `perform`
    /// path. On success the task is stamped in the run log. A task can't start
    /// over one already running: the helper would run the tool twice at once.
    func run(_ task: MaintenanceTask) async {
        guard phase != .working else { return }
        // These run for minutes, and a Mac that idles to sleep part way through
        // leaves them stalled until it wakes.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Running a maintenance task"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Name the running action for the progress screen, and clear any prior
        // result and FDA-recovery flag so they only reflect this run's outcome.
        workingTitle = task.title
        taskResults[task.id] = nil
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
    /// the action, capture its result line, and stamp the run log. Surfaces
    /// `.failed` on any error.
    private func perform(_ kind: MaintenanceTask.Kind, action: RunTask) async {
        phase = .working
        do {
            let result = try await action()
            taskResults[kind.rawValue] = result
            runLog.record(kind.rawValue)
            phase = .ready
        } catch {
            log.error("Maintenance task \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            if case MailReindexerError.fullDiskAccessRequired = error {
                failureNeedsFullDiskAccess = true
                // Counts as this week's try. Declining the permission is the
                // user's call, and it shouldn't hold the dashboard's card up
                // until they change their mind.
                runLog.record(kind.rawValue)
            }
            phase = .failed(message: taskFailureMessage(for: error))
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
    }

    /// What a failed task tells the user. A tool's own error is an exit status
    /// that means nothing to them (it is in the log), and a task that outlives
    /// the watchdog is usually still working in the helper, so "restart the app"
    /// would be the wrong advice.
    private func taskFailureMessage(for error: Error) -> String {
        let title = workingTitle ?? ""
        if case HelperConnectionError.timedOut = error {
            let format = String(
                localized: "“%@” is taking longer than expected and may still be running. Wait a few minutes before trying again.",
                bundle: .module,
                comment: "Failure message when a maintenance task outlives its timeout; %@ is the task title."
            )
            return String.localizedStringWithFormat(format, title)
        }
        if (error as NSError).domain == HelperErrorDomain.tool {
            let format = String(
                localized: "macOS couldn't finish “%@”. Try again later.",
                bundle: .module,
                comment: "Failure message when a system tool behind a maintenance task fails; %@ is the task title."
            )
            return String.localizedStringWithFormat(format, title)
        }
        return HelperConnectionError.userFacingMessage(for: error)
    }

    /// Runs the given tasks in order — the action behind the catalog's
    /// multi-select "Run" bar. Stops at the first failure, which surfaces
    /// `.failed` so the user sees what went wrong.
    public func run(_ tasks: [MaintenanceTask]) async {
        guard phase != .working, !isRunningBatch else { return }
        // Hold the progress screen for the whole batch so the UI doesn't flicker
        // as each task's phase flips between .working and .ready.
        isRunningBatch = true
        defer { isRunningBatch = false }
        for task in tasks {
            await run(task)
            if case .failed = phase { return }
        }
    }

    /// Number of maintenance-cocktail tasks currently due — the count behind the
    /// dashboard's Maintenance card.
    public var maintenanceTasksDue: Int {
        runLog.staleTaskCount(among: availableCocktailIDs)
    }

    /// The tasks behind that count, which the card's Review marks and preselects
    /// so the number on the card leads somewhere.
    public var dueMaintenanceTaskIDs: Set<String> {
        Set(runLog.staleTaskIDs(among: availableCocktailIDs))
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
                bundle: .module,
                comment: "Result line after a successful RAM flush; %@ is a used/total memory string."
            )
            ramResult = String.localizedStringWithFormat(
                format, SystemStatsFormatters.memoryUsageString(memory)
            )
            phase = .ready
        } catch {
            log.error("RAM flush failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(message: taskFailureMessage(for: error))
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
            log.error("Maintenance scripts failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(message: taskFailureMessage(for: error))
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
            log.error("Login-item toggle failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Opens System Settings to the Login Items pane. Used by a row that is
    /// registered but pending the user's approval — macOS grants that approval
    /// only in System Settings, so this is the closest we can get to an in-app
    /// approval: a one-click deep link instead of manual navigation.
    public func openLoginItemsSettings() {
        openLoginItemsSettingsAction()
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
    public func enable(_ agent: LaunchAgent) async {
        await setLoaded(agent, to: true, via: enableAgent)
    }

    /// Unloads an agent from launchd. Only user agents have a toggle, so the
    /// row updates in place via `setLoaded` rather than reloading the section.
    public func disable(_ agent: LaunchAgent) async {
        await setLoaded(agent, to: false, via: disableAgent)
    }

    /// Toggles a user agent's loaded state with an optimistic, in-place update:
    /// the switch flips immediately and neither a progress screen nor a list
    /// reload disturbs the rest of the section, so only the affected row
    /// animates. If launchctl fails or launchd doesn't apply the change the
    /// action throws and the row is restored to its prior state. Taking a new
    /// generation drops any reload in flight, whose read predates this change.
    private func setLoaded(
        _ agent: LaunchAgent,
        to enabled: Bool,
        via action: (LaunchAgent) async throws -> Void
    ) async {
        guard let index = userAgents.firstIndex(where: { $0.id == agent.id }) else { return }
        _ = beginLoad()
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
            log.error("Agent loaded-state change failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Removes a multi-selection from the Performance Manager's footer
    /// "Remove": each selected login item is unregistered (the host app's only
    /// truthful "remove" via `SMAppService`) and each selected *user* agent is
    /// stopped and its plist moved to the Trash. System daemons are protected —
    /// they live in launchd's privileged domain, so a selected `.system` id is
    /// ignored here even though the UI already withholds the checkbox from them.
    ///
    /// Every selected item gets its attempt, and the panes reload whatever
    /// happened, so one stuck item can't strand the rest and the lists never
    /// claim something still exists after it has gone. Any failure then surfaces
    /// `.failed`; the items that failed are still listed for a retry.
    public func removeSelected(loginItemIDs: Set<String>, agentIDs: Set<String>) async {
        guard phase != .working, !isRunningBatch else { return }
        let generation = beginLoad()
        phase = .working
        let selectedLoginItems = loginItems.filter { loginItemIDs.contains($0.id) }
        // Only user agents are removable; system daemons are never touched.
        let selectedAgents = userAgents.filter { agentIDs.contains($0.id) }

        var failures: [Error] = []
        for item in selectedLoginItems {
            do {
                try await setLoginItemEnabled(false, item)
            } catch {
                failures.append(error)
            }
        }
        for agent in selectedAgents {
            do {
                try await removeAgent(agent)
            } catch {
                failures.append(error)
            }
        }
        await reloadLists(generation: generation)

        guard let firstFailure = failures.first else {
            phase = .ready
            return
        }
        log.error("Batch remove failed for \(failures.count, privacy: .public) items: \(firstFailure.localizedDescription, privacy: .private)")
        let attempted = selectedLoginItems.count + selectedAgents.count
        phase = .failed(message: removalFailureMessage(
            firstFailure, failed: failures.count, attempted: attempted
        ))
    }

    private func removalFailureMessage(_ error: Error, failed: Int, attempted: Int) -> String {
        let reason = HelperConnectionError.userFacingMessage(for: error)
        guard attempted > 1 else { return reason }
        let format = String(
            localized: "Couldn't remove %1$lld of %2$lld items. %3$@",
            bundle: .module,
            comment: "Failure message after a batch remove; %1$lld failed out of %2$lld attempted, %3$@ is the first reason."
        )
        return String.localizedStringWithFormat(format, failed, attempted, reason)
    }

    /// Returns the VM to `.ready` after a `.failed` phase so the user can
    /// retry without re-running discovery.
    public func dismissResult() {
        failureNeedsFullDiskAccess = false
        phase = .ready
    }

    // MARK: - Generations

    private func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }
}

// MARK: - Production wiring

extension PerformanceViewModel {

    /// Builds a view-model wired to the real login-item / launch-agent /
    /// RAM / maintenance collaborators. Discovery runs off the main actor so
    /// the filesystem walk and `launchctl list` don't block the UI. The RAM
    /// figure in a flush's result line is read from the shared
    /// `SystemStatsService` so it and the Health Monitor never disagree.
    @MainActor
    public static func live(
        systemStats: SystemStatsService,
        preferences: PreferencesStore
    ) -> PerformanceViewModel {
        let loginManager = LoginItemsManager.live()
        let agentManager = LaunchAgentManager()
        let ram = RAMManager()
        let maintenance = MaintenanceScriptRunner()
        let dnsFlusher = DNSCacheFlusher()
        let spotlight = SpotlightReindexer()
        let snapshotThinner = TimeMachineSnapshotThinner()
        let mail = MailReindexer()

        return PerformanceViewModel(
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
            // updates in lockstep. The throwing variant rethrows a failed
            // registration so `setLoginItem` can surface it inline instead of
            // the global "Launch at Login" alert.
            setLoginItemEnabled: { enabled, _ in
                // The store queues the registration behind any write still in
                // flight and runs it off the main actor; this returns once
                // launchd has answered.
                try await preferences.setLaunchAtLogin(enabled)
            },
            // A login item macOS holds in `.requiresApproval` can only be
            // approved by the user in System Settings; deep-link straight to
            // the Login Items pane so that's one click, not a manual hunt.
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() },
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
            // `periodic` was removed in macOS 26; when it's absent, Run
            // Maintenance Scripts is hidden and never counted as due.
            maintenanceScriptsAvailable: FileManager.default.fileExists(atPath: "/usr/sbin/periodic"),
            // Reflect a Preferences-side toggle in this view's row. See
            // the `init` comment for why ordering matters here. The bridge
            // converts `PreferencesStore`'s Observation-tracked property
            // into the `AsyncStream` the view-model consumes, so the test
            // surface (a stream fed by `AsyncStream.makeStream()`) stays
            // the same shape as production.
            launchAtLoginChanges: launchAtLoginChanges(for: preferences)
        )
    }

    /// Bridges `PreferencesStore.launchAtLogin` (an Observation-tracked
    /// property) into an `AsyncStream<Void>`. Each detected change hops back
    /// to the main actor before re-arming the registration —
    /// `withObservationTracking`'s `onChange` fires exactly once per
    /// registration, so the closure that wants a continuous stream must
    /// re-register itself after every change — and is yielded only once the
    /// store's write to launchd has landed. Exposed `internal` so the
    /// integration test in `PerformanceViewModelTests` can wire up the
    /// same bridge `live()` builds and pin the willSet/didSet ordering.
    @MainActor
    static func launchAtLoginChanges(
        for preferences: PreferencesStore
    ) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let bridge = LaunchAtLoginBridge(preferences: preferences, continuation: continuation)
        bridge.arm()
        return stream
    }
}

/// Backing state for `PerformanceViewModel.launchAtLoginChanges(for:)`.
///
/// Exists so `withObservationTracking`'s `@Sendable` `onChange` closure captures
/// one box rather than the continuation and the re-arm function separately,
/// neither of which is `Sendable`. `@unchecked Sendable` is sound here because
/// every member is created and touched only on the main actor: `arm()` is
/// `@MainActor`, and the change callback hops back to it before yielding or
/// re-arming.
private final class LaunchAtLoginBridge: @unchecked Sendable {

    private let preferences: PreferencesStore
    private let continuation: AsyncStream<Void>.Continuation

    init(preferences: PreferencesStore, continuation: AsyncStream<Void>.Continuation) {
        self.preferences = preferences
        self.continuation = continuation
    }

    @MainActor
    func arm() {
        withObservationTracking {
            _ = preferences.launchAtLogin
        } onChange: { [self] in
            Task { @MainActor in
                // Re-arm before waiting, so a change made while this one's
                // write is in flight still gets an element of its own.
                arm()
                // The toggle moves before launchd has the change — the store
                // applies it off the main actor — and a row re-read any
                // sooner would show the state being replaced.
                await preferences.waitForLaunchAtLoginWrites()
                continuation.yield(())
            }
        }
    }
}

// MARK: - ScanCoordinating

extension PerformanceViewModel: ScanCoordinating {

    /// Projects the rich `Phase` onto the three coarse phases ContentView
    /// switches on. Performance has no idle-triggered scan — `.ready` is the
    /// loaded review surface and `.working`/`.failed` are action outcomes —
    /// so all three collapse to `.results`, the section's own detail UI.
    public var scanPresentation: ScanPresentation {
        switch phase {
        case .idle:
            return .intro
        case .loading:
            return .working
        case .ready, .working, .failed:
            return .results
        }
    }

    public func beginScan() {
        // Semantic stretch: Performance has no scan. "Scan" here means
        // "load" — the same `refresh()` the view runs on appear, which
        // populates login items / agents and drives
        // `.idle → .loading → .ready`.
        //
        // `refresh()`'s generation token prevents stale writes but not
        // redundant work, so skip kicking off another load while one (or
        // an action in `.working`) is already in flight.
        guard phase != .loading, phase != .working else { return }
        runScanActivity { await self.refresh() }
    }
}
