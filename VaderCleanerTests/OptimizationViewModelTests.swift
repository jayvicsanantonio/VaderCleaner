// OptimizationViewModelTests.swift
// Drives the OptimizationViewModel state machine — load, RAM flush, maintenance scripts, login-item toggle, and agent disable/remove — through injected fakes.

import XCTest
import Combine
@testable import VaderCleaner

@MainActor
final class OptimizationViewModelTests: XCTestCase {

    // MARK: - Initial state

    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.loginItems.isEmpty)
        XCTAssertTrue(vm.userAgents.isEmpty)
        XCTAssertTrue(vm.systemAgents.isEmpty)
    }

    // MARK: - Refresh

    func test_refresh_populatesAllSectionsAndBecomesReady() async {
        let vm = makeViewModel(
            loadLoginItems: { [Self.loginItem(name: "VaderCleaner")] },
            loadUserAgents: { [Self.agent(label: "com.user.a", domain: .user)] },
            loadSystemAgents: { [Self.agent(label: "com.sys.b", domain: .system)] },
            readMemory: { MemoryStats(usedBytes: 8, totalBytes: 16) }
        )

        await vm.refresh()

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.loginItems.map(\.name), ["VaderCleaner"])
        XCTAssertEqual(vm.userAgents.map(\.label), ["com.user.a"])
        XCTAssertEqual(vm.systemAgents.map(\.label), ["com.sys.b"])
        XCTAssertEqual(vm.memory, MemoryStats(usedBytes: 8, totalBytes: 16))
    }

    // MARK: - RAM flush

    func test_flushRAM_callsPrivilegedHelperAndShowsResult() async {
        var flushed = false
        let vm = makeViewModel(
            readMemory: { MemoryStats(usedBytes: 4, totalBytes: 16) },
            flushRAM: { flushed = true }
        )
        await vm.refresh()

        await vm.flushRAM()

        XCTAssertTrue(flushed, "flushRAM() must invoke the privileged helper collaborator")
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNotNil(vm.ramResult)
    }

    func test_flushRAM_failureTransitionsToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(flushRAM: { throw Boom() })
        await vm.refresh()

        await vm.flushRAM()

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Maintenance scripts

    func test_runMaintenanceScripts_callsPrivilegedHelperAndCapturesOutput() async {
        var ran = false
        let vm = makeViewModel(runMaintenance: {
            ran = true
            return "Maintenance complete."
        })
        await vm.refresh()

        await vm.runMaintenanceScripts()

        XCTAssertTrue(ran, "runMaintenanceScripts() must invoke the privileged helper collaborator")
        XCTAssertEqual(vm.maintenanceOutput, "Maintenance complete.")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_runMaintenanceScripts_failureTransitionsToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(runMaintenance: { throw Boom() })
        await vm.refresh()

        await vm.runMaintenanceScripts()

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Maintenance task catalog

    func test_runTask_flushDNS_invokesRunnerStampsResultAndReady() async {
        var ran = false
        let vm = makeViewModel(flushDNS: { ran = true; return "Flushed DNS." })
        await vm.refresh()

        await vm.run(Self.task(.flushDNS))

        XCTAssertTrue(ran, "run(.flushDNS) must invoke its runner")
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.taskResults["flushDNS"], "Flushed DNS.")
    }

    func test_runTask_speedUpMail_failureTransitionsToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(speedUpMail: { throw Boom() })
        await vm.refresh()

        await vm.run(Self.task(.speedUpMail))

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
        XCTAssertFalse(vm.failureNeedsFullDiskAccess, "A generic failure is not an FDA recovery case")
    }

    func test_runTask_speedUpMail_fullDiskAccessFailureFlagsRecovery() async {
        let vm = makeViewModel(speedUpMail: { throw MailReindexerError.fullDiskAccessRequired })
        await vm.refresh()

        await vm.run(Self.task(.speedUpMail))

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
        XCTAssertTrue(vm.failureNeedsFullDiskAccess,
                      "A Full Disk Access failure must flag the recovery affordance")
    }

    func test_runTask_recordsLastRunSoTaskIsNoLongerStale() async {
        let suiteName = "OptVMRunLog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let log = MaintenanceRunLog(defaults: defaults)
        let vm = makeViewModel(flushDNS: { "ok" }, runLog: log)
        await vm.refresh()
        XCTAssertNil(log.lastRun(for: "flushDNS"))

        await vm.run(Self.task(.flushDNS))

        XCTAssertNotNil(log.lastRun(for: "flushDNS"))
    }

    func test_run_clearsWorkingTitleWhenFinished() async {
        let vm = makeViewModel(flushDNS: { "Flushed the DNS resolver cache." })
        await vm.refresh()

        await vm.run(Self.task(.flushDNS))

        XCTAssertNil(vm.workingTitle, "The progress title clears when the action finishes")
    }

    func test_runRecommendation_marksTileCompletedOnSuccess() async {
        var freed = false
        let vm = makeViewModel(flushRAM: { freed = true })
        await vm.refresh()

        await vm.runRecommendation(Self.recommendation(.freeUpRAM))

        XCTAssertTrue(freed, "Running the Free Up RAM tile must invoke the RAM flush")
        XCTAssertTrue(vm.completedRecommendations.contains(.freeUpRAM))
    }

    func test_runRecommendation_failureDoesNotMarkCompleted() async {
        struct Boom: Error {}
        let vm = makeViewModel(flushRAM: { throw Boom() })
        await vm.refresh()

        await vm.runRecommendation(Self.recommendation(.freeUpRAM))

        XCTAssertFalse(vm.completedRecommendations.contains(.freeUpRAM),
                       "A failed action must not mark the tile complete")
    }

    func test_runRecommendation_backgroundItems_isNavigationOnly() async {
        var flushed = false
        let vm = makeViewModel(flushRAM: { flushed = true })
        await vm.refresh()

        await vm.runRecommendation(Self.recommendation(.backgroundItems))

        XCTAssertFalse(flushed, "The background-items tile only navigates; it runs nothing")
        XCTAssertFalse(vm.completedRecommendations.contains(.backgroundItems))
    }

    func test_refresh_clearsCompletedRecommendations() async {
        let vm = makeViewModel(flushRAM: {})
        await vm.refresh()
        await vm.runRecommendation(Self.recommendation(.freeUpRAM))
        XCTAssertTrue(vm.completedRecommendations.contains(.freeUpRAM))

        await vm.refresh()

        XCTAssertTrue(vm.completedRecommendations.isEmpty, "A refresh clears completed-tile marks")
    }

    func test_tasks_excludeMaintenanceScriptsWhenPeriodicUnavailable() async {
        let vm = makeViewModel(maintenanceScriptsAvailable: false)
        await vm.refresh()

        XCTAssertFalse(
            vm.tasks.contains { $0.kind == .runMaintenanceScripts },
            "Run Maintenance Scripts must be hidden when /usr/sbin/periodic is absent"
        )
        // The other tasks remain.
        XCTAssertTrue(vm.tasks.contains { $0.kind == .flushDNS })
    }

    func test_runDueMaintenance_skipsMaintenanceScriptsWhenUnavailable() async {
        var ranScripts = false
        var ranDNS = false
        let vm = makeViewModel(
            runMaintenance: { ranScripts = true; return "scripts" },
            flushDNS: { ranDNS = true; return "dns" },
            maintenanceScriptsAvailable: false
        )
        await vm.refresh()

        await vm.runDueMaintenance()

        XCTAssertFalse(ranScripts, "The removed periodic task must never be invoked")
        XCTAssertTrue(ranDNS, "The available cocktail tasks still run")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_runDueMaintenance_runsEveryDueCocktailTask() async {
        // Fresh run log → every cocktail task is due. Each runner records that
        // it ran; RAM and Thin TM are excluded from the cocktail.
        var ranScripts = false, ranDNS = false, ranSpotlight = false, ranMail = false
        let vm = makeViewModel(
            runMaintenance: { ranScripts = true; return "scripts" },
            flushDNS: { ranDNS = true; return "dns" },
            reindexSpotlight: { ranSpotlight = true; return "spotlight" },
            speedUpMail: { ranMail = true; return "mail" }
        )
        await vm.refresh()

        await vm.runDueMaintenance()

        XCTAssertTrue(ranScripts && ranDNS && ranSpotlight && ranMail,
                      "runDueMaintenance() must run every due cocktail task")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_runTasks_runsEverySelectedTaskInOrder() async {
        var ranDNS = false, ranSpotlight = false
        let vm = makeViewModel(
            flushDNS: { ranDNS = true; return "dns" },
            reindexSpotlight: { ranSpotlight = true; return "spotlight" }
        )
        await vm.refresh()

        await vm.run([Self.task(.flushDNS), Self.task(.reindexSpotlight)])

        XCTAssertTrue(ranDNS && ranSpotlight, "Both selected tasks must run")
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.taskResults["flushDNS"], "dns")
        XCTAssertEqual(vm.taskResults["reindexSpotlight"], "spotlight")
    }

    func test_runTasks_stopsAtFirstFailure() async {
        struct Boom: Error {}
        var ranSpotlight = false
        let vm = makeViewModel(
            flushDNS: { throw Boom() },
            reindexSpotlight: { ranSpotlight = true; return "spotlight" }
        )
        await vm.refresh()

        await vm.run([Self.task(.flushDNS), Self.task(.reindexSpotlight)])

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
        XCTAssertFalse(ranSpotlight, "A failure must halt the remaining tasks")
    }

    func test_refresh_buildsRecommendationsFromSystemState() async {
        let vm = makeViewModel(
            loadLoginItems: { [Self.loginItem(name: "A")] },
            readMemory: { MemoryStats(usedBytes: 15, totalBytes: 16) }, // high pressure
            readSnapshotCount: { 3 }
        )

        await vm.refresh()

        XCTAssertTrue(vm.recommendations.contains { $0.kind == .freeUpRAM })
        XCTAssertTrue(vm.recommendations.contains { $0.kind == .backgroundItems })
        XCTAssertTrue(vm.recommendations.contains { $0.kind == .thinSnapshots })
    }

    // MARK: - Login items

    func test_setLoginItem_forwardsRequestedStateToCollaborator() async {
        var received: (Bool, String)?
        let item = Self.loginItem(name: "VaderCleaner")
        let vm = makeViewModel(
            loadLoginItems: { [item] },
            setLoginItemEnabled: { enabled, target in
                received = (enabled, target.name)
            }
        )
        await vm.refresh()

        await vm.setLoginItem(item, enabled: false)

        XCTAssertEqual(received?.0, false)
        XCTAssertEqual(received?.1, "VaderCleaner")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_setLoginItem_failureTransitionsToFailed() async {
        struct Boom: Error {}
        let item = Self.loginItem(name: "VaderCleaner")
        let vm = makeViewModel(
            loadLoginItems: { [item] },
            setLoginItemEnabled: { _, _ in throw Boom() }
        )
        await vm.refresh()

        await vm.setLoginItem(item, enabled: false)

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Launch-at-login cross-update (issue #65)

    /// An external change to the launch-at-login preference (the
    /// Preferences toggle) must reload the Optimization login-items row
    /// so the two surfaces never disagree within a session.
    func test_externalLaunchAtLoginChange_reloadsLoginItems() async {
        let subject = PassthroughSubject<Void, Never>()
        var loadCount = 0
        let vm = makeViewModel(
            loadLoginItems: {
                loadCount += 1
                // First load (refresh) reports disabled; after the
                // external change the backing state reads enabled.
                return [LoginItem(id: "host", name: "VaderCleaner", isEnabled: loadCount > 1)]
            },
            launchAtLoginChanges: subject.eraseToAnyPublisher()
        )
        await vm.refresh()
        XCTAssertEqual(vm.loginItems.first?.isEnabled, false)

        subject.send(())
        await waitUntil { vm.loginItems.first?.isEnabled == true }

        XCTAssertEqual(vm.loginItems.first?.isEnabled, true)
    }

    /// With no publisher injected (the unit-test / preview default),
    /// nothing subscribes and the row only changes on explicit
    /// refresh/toggle — the prior behavior is preserved.
    func test_noLaunchAtLoginPublisher_rowOnlyChangesOnExplicitReload() async {
        var loadCount = 0
        let vm = makeViewModel(
            loadLoginItems: {
                loadCount += 1
                return [LoginItem(id: "host", name: "VaderCleaner", isEnabled: true)]
            }
        )
        await vm.refresh()
        XCTAssertEqual(loadCount, 1)
        // No publisher → no spontaneous reload path exists.
        XCTAssertEqual(vm.loginItems.map(\.name), ["VaderCleaner"])
    }

    /// End-to-end with a real `PreferencesStore`: a Preferences-side
    /// toggle reaches the Optimization row, an Optimization-side toggle
    /// writes back through `PreferencesStore`, and the SMAppService
    /// handler runs exactly once per change — no duplicated write path.
    /// Also pins the `@Published` willSet/didSet ordering: the row is
    /// reloaded *after* the handler has applied the new state.
    func test_integration_optimizationAndPreferencesStayInSync() async {
        let suiteName = "VaderCleanerTests.Issue65.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "preferences.launchAtLogin")

        // Stand-in for SMAppService: the handler is the only thing that
        // mutates `loginEnabled`, exactly like the production single
        // write path through PreferencesStore.didSet.
        var loginEnabled = false
        var handlerCalls = 0
        let prefs = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { enabled in
                handlerCalls += 1
                loginEnabled = enabled
            }
        )
        // init's reconcile pushes the persisted value once; reset so the
        // assertions below count only user-driven toggles.
        handlerCalls = 0

        let vm = makeViewModel(
            loadLoginItems: {
                [LoginItem(id: "host", name: "VaderCleaner", isEnabled: loginEnabled)]
            },
            setLoginItemEnabled: { enabled, _ in prefs.launchAtLogin = enabled },
            launchAtLoginChanges: OptimizationViewModel.launchAtLoginChangePublisher(for: prefs)
        )
        await vm.refresh()
        XCTAssertEqual(vm.loginItems.first?.isEnabled, false)

        // Preferences → Optimization.
        prefs.launchAtLogin = true
        await waitUntil { vm.loginItems.first?.isEnabled == true }
        XCTAssertEqual(vm.loginItems.first?.isEnabled, true)
        XCTAssertEqual(handlerCalls, 1, "exactly one SMAppService write via the single path")

        // Optimization → Preferences.
        await vm.setLoginItem(
            LoginItem(id: "host", name: "VaderCleaner", isEnabled: true),
            enabled: false
        )
        XCTAssertFalse(prefs.launchAtLogin, "Optimization toggle writes through PreferencesStore")
        XCTAssertEqual(vm.loginItems.first?.isEnabled, false)
        XCTAssertEqual(handlerCalls, 2, "no duplicated write path")
    }

    // MARK: - Agent disable / remove

    func test_disableAgent_flipsRowOptimisticallyWithoutReloadingOrWorkingPhase() async {
        var disabled: String?
        var userLoads = 0
        // Self.agent starts enabled; disabling should flip just this row.
        let agent = Self.agent(label: "com.user.a", domain: .user)
        let vm = makeViewModel(
            loadUserAgents: { userLoads += 1; return [agent] },
            disableAgent: { disabled = $0.label }
        )
        await vm.refresh()
        let loadsAfterRefresh = userLoads

        await vm.disable(agent)

        XCTAssertEqual(disabled, "com.user.a")
        XCTAssertEqual(vm.userAgents.first?.isEnabled, false, "row flips in place")
        XCTAssertEqual(userLoads, loadsAfterRefresh, "no list reload")
        XCTAssertEqual(vm.phase, .ready, "no progress screen")
    }

    func test_enableAgent_flipsRowOptimisticallyWithoutReloadingOrWorkingPhase() async {
        var enabled: String?
        var userLoads = 0
        let agent = LaunchAgent(
            label: "com.user.a", path: URL(fileURLWithPath: "/tmp/com.user.a.plist"),
            programPath: "/bin/true", isEnabled: false, domain: .user
        )
        let vm = makeViewModel(
            loadUserAgents: { userLoads += 1; return [agent] },
            enableAgent: { enabled = $0.label }
        )
        await vm.refresh()
        let loadsAfterRefresh = userLoads

        await vm.enable(agent)

        XCTAssertEqual(enabled, "com.user.a")
        XCTAssertEqual(vm.userAgents.first?.isEnabled, true, "row flips in place")
        XCTAssertEqual(userLoads, loadsAfterRefresh, "no list reload")
        XCTAssertEqual(vm.phase, .ready, "no progress screen")
    }

    func test_disableAgent_revertsRowAndFailsWhenActionThrows() async {
        struct ToggleError: Error {}
        let agent = Self.agent(label: "com.user.a", domain: .user) // enabled
        let vm = makeViewModel(
            loadUserAgents: { [agent] },
            disableAgent: { _ in throw ToggleError() }
        )
        await vm.refresh()

        await vm.disable(agent)

        XCTAssertEqual(vm.userAgents.first?.isEnabled, true, "row reverts on failure")
        guard case .failed = vm.phase else {
            return XCTFail("expected .failed phase, got \(vm.phase)")
        }
    }

    func test_removeAgent_dropsRowAndReturnsToReady() async {
        let target = Self.agent(label: "com.user.doomed", domain: .user)
        let keep = Self.agent(label: "com.user.keep", domain: .user)
        let vm = makeViewModel(
            loadUserAgents: { [target, keep] },
            removeAgent: { _ in }
        )
        await vm.refresh()

        await vm.remove(target)

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.userAgents.map(\.label), ["com.user.keep"])
    }

    func test_removeAgent_failureLeavesListIntact() async {
        struct Boom: Error {}
        let target = Self.agent(label: "com.user.doomed", domain: .user)
        let vm = makeViewModel(
            loadUserAgents: { [target] },
            removeAgent: { _ in throw Boom() }
        )
        await vm.refresh()

        await vm.remove(target)

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
        XCTAssertEqual(vm.userAgents.map(\.label), ["com.user.doomed"])
    }

    func test_removeAgent_systemDaemonIsProtectedAndNotRemoved() async {
        var removeCalled = false
        let systemDaemon = Self.agent(label: "com.apple.somethingImportant", domain: .system)
        let vm = makeViewModel(
            loadSystemAgents: { [systemDaemon] },
            removeAgent: { _ in removeCalled = true }
        )
        await vm.refresh()

        await vm.remove(systemDaemon)

        XCTAssertFalse(removeCalled, "System daemons must never be removed")
        XCTAssertEqual(vm.systemAgents.map(\.label), ["com.apple.somethingImportant"],
                       "The protected system daemon must remain in the list")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_dismissResult_returnsToReady() async {
        struct Boom: Error {}
        let vm = makeViewModel(flushRAM: { throw Boom() })
        await vm.refresh()
        await vm.flushRAM()

        vm.dismissResult()

        XCTAssertEqual(vm.phase, .ready)
    }

    // MARK: - Helpers

    private func makeViewModel(
        loadLoginItems: @escaping OptimizationViewModel.LoadLoginItems = { [] },
        loadUserAgents: @escaping OptimizationViewModel.LoadAgents = { [] },
        loadSystemAgents: @escaping OptimizationViewModel.LoadAgents = { [] },
        readMemory: @escaping OptimizationViewModel.ReadMemory = { .empty },
        setLoginItemEnabled: @escaping OptimizationViewModel.SetLoginItemEnabled = { _, _ in },
        disableAgent: @escaping OptimizationViewModel.DisableAgent = { _ in },
        enableAgent: @escaping OptimizationViewModel.EnableAgent = { _ in },
        removeAgent: @escaping OptimizationViewModel.RemoveAgent = { _ in },
        flushRAM: @escaping OptimizationViewModel.FlushRAM = {},
        runMaintenance: @escaping OptimizationViewModel.RunMaintenance = { "" },
        flushDNS: @escaping OptimizationViewModel.RunTask = { "" },
        reindexSpotlight: @escaping OptimizationViewModel.RunTask = { "" },
        thinSnapshots: @escaping OptimizationViewModel.RunTask = { "" },
        speedUpMail: @escaping OptimizationViewModel.RunTask = { "" },
        readSnapshotCount: @escaping OptimizationViewModel.ReadSnapshotCount = { 0 },
        runLog: MaintenanceRunLog? = nil,
        maintenanceScriptsAvailable: Bool = true,
        launchAtLoginChanges: AnyPublisher<Void, Never>? = nil
    ) -> OptimizationViewModel {
        // Default to an isolated, empty UserDefaults suite so the run log never
        // touches `.standard` or leaks state between tests.
        let isolatedLog = runLog ?? MaintenanceRunLog(
            defaults: UserDefaults(suiteName: "OptimizationViewModelTests.\(UUID().uuidString)")!
        )
        return OptimizationViewModel(
            loadLoginItems: loadLoginItems,
            loadUserAgents: loadUserAgents,
            loadSystemAgents: loadSystemAgents,
            readMemory: readMemory,
            setLoginItemEnabled: setLoginItemEnabled,
            disableAgent: disableAgent,
            enableAgent: enableAgent,
            removeAgent: removeAgent,
            flushRAM: flushRAM,
            runMaintenance: runMaintenance,
            flushDNS: flushDNS,
            reindexSpotlight: reindexSpotlight,
            thinSnapshots: thinSnapshots,
            speedUpMail: speedUpMail,
            readSnapshotCount: readSnapshotCount,
            runLog: isolatedLog,
            maintenanceScriptsAvailable: maintenanceScriptsAvailable,
            launchAtLoginChanges: launchAtLoginChanges
        )
    }

    private static func task(_ kind: MaintenanceTask.Kind) -> MaintenanceTask {
        MaintenanceTask.catalog.first { $0.kind == kind }!
    }

    private static func recommendation(_ kind: PerformanceRecommendation.Kind) -> PerformanceRecommendation {
        PerformanceRecommendation(
            kind: kind, title: "", detail: "", icon: "", actionLabel: "", isHero: kind == .freeUpRAM
        )
    }

    private static func loginItem(name: String) -> LoginItem {
        LoginItem(id: name, name: name, isEnabled: true)
    }

    private static func agent(
        label: String,
        domain: LaunchAgent.Domain
    ) -> LaunchAgent {
        LaunchAgent(
            label: label,
            path: URL(fileURLWithPath: "/tmp/\(label).plist"),
            programPath: "/bin/true",
            isEnabled: true,
            domain: domain
        )
    }
}
