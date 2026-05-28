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
    typealias RemoveAgent = (LaunchAgent) async throws -> Void
    typealias FlushRAM = () async throws -> Void
    typealias RunMaintenance = () async throws -> String

    private(set) var phase: Phase = .idle
    private(set) var loginItems: [LoginItem] = []
    private(set) var userAgents: [LaunchAgent] = []
    private(set) var systemAgents: [LaunchAgent] = []
    private(set) var memory: MemoryStats = .empty
    private(set) var ramResult: String?
    private(set) var maintenanceOutput: String?

    @ObservationIgnored private let loadLoginItems: LoadLoginItems
    @ObservationIgnored private let loadUserAgents: LoadAgents
    @ObservationIgnored private let loadSystemAgents: LoadAgents
    @ObservationIgnored private let readMemory: ReadMemory
    @ObservationIgnored private let setLoginItemEnabled: SetLoginItemEnabled
    @ObservationIgnored private let disableAgent: DisableAgent
    @ObservationIgnored private let removeAgent: RemoveAgent
    @ObservationIgnored private let flushRAMAction: FlushRAM
    @ObservationIgnored private let runMaintenance: RunMaintenance

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
        removeAgent: @escaping RemoveAgent,
        flushRAM: @escaping FlushRAM,
        runMaintenance: @escaping RunMaintenance,
        launchAtLoginChanges: AnyPublisher<Void, Never>? = nil
    ) {
        self.loadLoginItems = loadLoginItems
        self.loadUserAgents = loadUserAgents
        self.loadSystemAgents = loadSystemAgents
        self.readMemory = readMemory
        self.setLoginItemEnabled = setLoginItemEnabled
        self.disableAgent = disableAgent
        self.removeAgent = removeAgent
        self.flushRAMAction = flushRAM
        self.runMaintenance = runMaintenance

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
        let (loadedLogin, loadedUser, loadedSystem) = await (login, user, system)
        let mem = readMemory()

        guard loadGeneration == generation else { return }
        loginItems = loadedLogin
        userAgents = loadedUser
        systemAgents = loadedSystem
        memory = mem
        phase = .ready
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

    /// Unloads an agent from launchd, then reloads both agent lists so the
    /// loaded/enabled state is refreshed.
    func disable(_ agent: LaunchAgent) async {
        phase = .working
        do {
            try await disableAgent(agent)
            async let user = loadUserAgents()
            async let system = loadSystemAgents()
            let (reloadedUser, reloadedSystem) = await (user, system)
            userAgents = reloadedUser
            systemAgents = reloadedSystem
            phase = .ready
        } catch {
            log.error("Agent disable failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: HelperConnectionError.userFacingMessage(for: error))
        }
    }

    /// Removes an agent's plist. On success the row is dropped; on failure
    /// the lists are left intact so the user can retry.
    func remove(_ agent: LaunchAgent) async {
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
            removeAgent: { try await agentManager.remove($0) },
            flushRAM: { try await ram.flush() },
            runMaintenance: { try await maintenance.run() },
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
