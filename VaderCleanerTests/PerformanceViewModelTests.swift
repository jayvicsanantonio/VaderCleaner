// PerformanceViewModelTests.swift
// Drives the PerformanceViewModel state machine — load, RAM flush, maintenance scripts, login-item toggle, and agent disable/remove — through injected fakes.

import XCTest
import Combine
@testable import VaderCleaner

@MainActor
final class PerformanceViewModelTests: XCTestCase {

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
        let flushed = TestBox(false)
        let vm = makeViewModel(
            readMemory: { MemoryStats(usedBytes: 4, totalBytes: 16) },
            flushRAM: { flushed.value = true }
        )
        await vm.refresh()

        await vm.flushRAM()

        XCTAssertTrue(flushed.value, "flushRAM() must invoke the privileged helper collaborator")
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
        let ran = TestBox(false)
        let vm = makeViewModel(runMaintenance: {
            ran.value = true
            return "Maintenance complete."
        })
        await vm.refresh()

        await vm.runMaintenanceScripts()

        XCTAssertTrue(ran.value, "runMaintenanceScripts() must invoke the privileged helper collaborator")
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
        let ran = TestBox(false)
        let vm = makeViewModel(flushDNS: { ran.value = true; return "Flushed DNS." })
        await vm.refresh()

        await vm.run(Self.task(.flushDNS))

        XCTAssertTrue(ran.value, "run(.flushDNS) must invoke its runner")
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
        let freed = TestBox(false)
        let vm = makeViewModel(flushRAM: { freed.value = true })
        await vm.refresh()

        await vm.runRecommendation(Self.recommendation(.freeUpRAM))

        XCTAssertTrue(freed.value, "Running the Free Up RAM tile must invoke the RAM flush")
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
        let flushed = TestBox(false)
        let vm = makeViewModel(flushRAM: { flushed.value = true })
        await vm.refresh()

        await vm.runRecommendation(Self.recommendation(.backgroundItems))

        XCTAssertFalse(flushed.value, "The background-items tile only navigates; it runs nothing")
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
        let ranScripts = TestBox(false)
        let ranDNS = TestBox(false)
        let vm = makeViewModel(
            runMaintenance: { ranScripts.value = true; return "scripts" },
            flushDNS: { ranDNS.value = true; return "dns" },
            maintenanceScriptsAvailable: false
        )
        await vm.refresh()

        await vm.runDueMaintenance()

        XCTAssertFalse(ranScripts.value, "The removed periodic task must never be invoked")
        XCTAssertTrue(ranDNS.value, "The available cocktail tasks still run")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_runDueMaintenance_runsEveryDueCocktailTask() async {
        // Fresh run log → every cocktail task is due. Each runner records that
        // it ran; RAM and Thin TM are excluded from the cocktail.
        let ranScripts = TestBox(false)
        let ranDNS = TestBox(false)
        let ranSpotlight = TestBox(false)
        let ranMail = TestBox(false)
        let vm = makeViewModel(
            runMaintenance: { ranScripts.value = true; return "scripts" },
            flushDNS: { ranDNS.value = true; return "dns" },
            reindexSpotlight: { ranSpotlight.value = true; return "spotlight" },
            speedUpMail: { ranMail.value = true; return "mail" }
        )
        await vm.refresh()

        await vm.runDueMaintenance()

        XCTAssertTrue(ranScripts.value && ranDNS.value && ranSpotlight.value && ranMail.value,
                      "runDueMaintenance() must run every due cocktail task")
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_runTasks_runsEverySelectedTaskInOrder() async {
        let ranDNS = TestBox(false)
        let ranSpotlight = TestBox(false)
        let vm = makeViewModel(
            flushDNS: { ranDNS.value = true; return "dns" },
            reindexSpotlight: { ranSpotlight.value = true; return "spotlight" }
        )
        await vm.refresh()

        await vm.run([Self.task(.flushDNS), Self.task(.reindexSpotlight)])

        XCTAssertTrue(ranDNS.value && ranSpotlight.value, "Both selected tasks must run")
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.taskResults["flushDNS"], "dns")
        XCTAssertEqual(vm.taskResults["reindexSpotlight"], "spotlight")
    }

    func test_runTasks_stopsAtFirstFailure() async {
        struct Boom: Error {}
        let ranSpotlight = TestBox(false)
        let vm = makeViewModel(
            flushDNS: { throw Boom() },
            reindexSpotlight: { ranSpotlight.value = true; return "spotlight" }
        )
        await vm.refresh()

        await vm.run([Self.task(.flushDNS), Self.task(.reindexSpotlight)])

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
        XCTAssertFalse(ranSpotlight.value, "A failure must halt the remaining tasks")
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
        let received = TestBox<(Bool, String)?>(nil)
        let item = Self.loginItem(name: "VaderCleaner")
        let vm = makeViewModel(
            loadLoginItems: { [item] },
            setLoginItemEnabled: { enabled, target in
                received.value = (enabled, target.name)
            }
        )
        await vm.refresh()

        await vm.setLoginItem(item, enabled: false)

        XCTAssertEqual(received.value?.0, false)
        XCTAssertEqual(received.value?.1, "VaderCleaner")
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

    func test_openLoginItemsSettings_invokesInjectedOpener() {
        var opened = 0
        let vm = makeViewModel(openLoginItemsSettings: { opened += 1 })

        vm.openLoginItemsSettings()

        XCTAssertEqual(opened, 1)
    }

    // MARK: - Launch-at-login cross-update (issue #65)

    /// An external change to the launch-at-login preference (the
    /// Preferences toggle) must reload the Performance login-items row
    /// so the two surfaces never disagree within a session.
    func test_externalLaunchAtLoginChange_reloadsLoginItems() async {
        let subject = PassthroughSubject<Void, Never>()
        let loadCount = TestBox(0)
        let vm = makeViewModel(
            loadLoginItems: {
                loadCount.value += 1
                // First load (refresh) reports disabled.value; after the
                // external change the backing state reads enabled.
                return [LoginItem(id: "host", name: "VaderCleaner", isEnabled: loadCount.value > 1)]
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
        let loadCount = TestBox(0)
        let vm = makeViewModel(
            loadLoginItems: {
                loadCount.value += 1
                return [LoginItem(id: "host", name: "VaderCleaner", isEnabled: true)]
            }
        )
        await vm.refresh()
        XCTAssertEqual(loadCount.value, 1)
        // No publisher → no spontaneous reload path exists.
        XCTAssertEqual(vm.loginItems.map(\.name), ["VaderCleaner"])
    }

    /// End-to-end with a real `PreferencesStore`: a Preferences-side
    /// toggle reaches the Performance row, an Performance-side toggle
    /// writes back through `PreferencesStore`, and the SMAppService
    /// handler runs exactly once per change — no duplicated write path.
    /// Also pins the `@Published` willSet/didSet ordering: the row is
    /// reloaded *after* the handler has applied the new state.
    func test_integration_performanceAndPreferencesStayInSync() async {
        let suiteName = "VaderCleanerTests.Issue65.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "preferences.launchAtLogin")

        // Stand-in for SMAppService: the handler is the only thing that
        // mutates `loginEnabled`, exactly like the production single
        // write path through PreferencesStore.didSet.
        let loginEnabled = TestBox(false)
        var handlerCalls = 0
        let prefs = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { enabled in
                handlerCalls += 1
                loginEnabled.value = enabled
            }
        )
        // init's reconcile pushes the persisted value once; reset so the
        // assertions below count only user-driven toggles.
        handlerCalls = 0

        let vm = makeViewModel(
            loadLoginItems: {
                [LoginItem(id: "host", name: "VaderCleaner", isEnabled: loginEnabled.value)]
            },
            setLoginItemEnabled: { enabled, _ in
                try await MainActor.run { try prefs.setLaunchAtLogin(enabled) }
            },
            launchAtLoginChanges: PerformanceViewModel.launchAtLoginChangePublisher(for: prefs)
        )
        await vm.refresh()
        XCTAssertEqual(vm.loginItems.first?.isEnabled, false)

        // Preferences → Performance.
        prefs.launchAtLogin = true
        await waitUntil { vm.loginItems.first?.isEnabled == true }
        XCTAssertEqual(vm.loginItems.first?.isEnabled, true)
        XCTAssertEqual(handlerCalls, 1, "exactly one SMAppService write via the single path")

        // Performance → Preferences.
        await vm.setLoginItem(
            LoginItem(id: "host", name: "VaderCleaner", isEnabled: true),
            enabled: false
        )
        XCTAssertFalse(prefs.launchAtLogin, "Performance toggle writes through PreferencesStore")
        XCTAssertEqual(vm.loginItems.first?.isEnabled, false)
        XCTAssertEqual(handlerCalls, 2, "no duplicated write path")
    }

    // MARK: - Agent disable / remove

    func test_disableAgent_flipsRowOptimisticallyWithoutReloadingOrWorkingPhase() async {
        let disabled = TestBox<String?>(nil)
        let userLoads = TestBox(0)
        // agent starts enabled; disabling should flip just this row.
        let agent = Self.agent(label: "com.user.a", domain: .user)
        let vm = makeViewModel(
            loadUserAgents: { userLoads.value += 1; return [agent] },
            disableAgent: { disabled.value = $0.label }
        )
        await vm.refresh()
        let loadsAfterRefresh = userLoads.value

        await vm.disable(agent)

        XCTAssertEqual(disabled.value, "com.user.a")
        XCTAssertEqual(vm.userAgents.first?.isEnabled, false, "row flips in place")
        XCTAssertEqual(userLoads.value, loadsAfterRefresh, "no list reload")
        XCTAssertEqual(vm.phase, .ready, "no progress screen")
    }

    func test_enableAgent_flipsRowOptimisticallyWithoutReloadingOrWorkingPhase() async {
        let enabled = TestBox<String?>(nil)
        let userLoads = TestBox(0)
        let agent = LaunchAgent(
            label: "com.user.a", path: URL(fileURLWithPath: "/tmp/com.user.a.plist"),
            programPath: "/bin/true", isEnabled: false, domain: .user
        )
        let vm = makeViewModel(
            loadUserAgents: { userLoads.value += 1; return [agent] },
            enableAgent: { enabled.value = $0.label }
        )
        await vm.refresh()
        let loadsAfterRefresh = userLoads.value

        await vm.enable(agent)

        XCTAssertEqual(enabled.value, "com.user.a")
        XCTAssertEqual(vm.userAgents.first?.isEnabled, true, "row flips in place")
        XCTAssertEqual(userLoads.value, loadsAfterRefresh, "no list reload")
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
        let removeCalled = TestBox(false)
        let systemDaemon = Self.agent(label: "com.apple.somethingImportant", domain: .system)
        let vm = makeViewModel(
            loadSystemAgents: { [systemDaemon] },
            removeAgent: { _ in removeCalled.value = true }
        )
        await vm.refresh()

        await vm.remove(systemDaemon)

        XCTAssertFalse(removeCalled.value, "System daemons must never be removed")
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

    // MARK: - Manager batch remove

    /// The Performance Manager's footer "Remove" acts on a multi-selection: it
    /// unregisters each selected login item and deletes each selected user
    /// agent, then reloads so the panes reflect the new state.
    func test_removeSelected_unregistersLoginItemsAndDeletesUserAgents() async {
        let unregistered = TestBox<[String]>([])
        let removedAgents = TestBox<[String]>([])
        let host = LoginItem(id: "com.personal.VaderCleaner", name: "VaderCleaner", isEnabled: true)
        let doomed = Self.agent(label: "com.user.doomed", domain: .user)
        let keep = Self.agent(label: "com.user.keep", domain: .user)
        let loginReloads = TestBox(0)
        let vm = makeViewModel(
            loadLoginItems: {
                loginReloads.value += 1
                // After removal the host reads disabled.value (unregistered.value).
                return [LoginItem(id: host.id, name: host.name, isEnabled: loginReloads.value == 1)]
            },
            loadUserAgents: { removedAgents.value.isEmpty ? [doomed, keep] : [keep] },
            setLoginItemEnabled: { enabled, item in
                if !enabled { unregistered.value.append(item.id) }
            },
            removeAgent: { removedAgents.value.append($0.label) }
        )
        await vm.refresh()

        await vm.removeSelected(loginItemIDs: [host.id], agentIDs: [doomed.id])

        XCTAssertEqual(unregistered.value, [host.id], "Selected login item should be unregistered.value")
        XCTAssertEqual(removedAgents.value, ["com.user.doomed"], "Only the selected user agent is removed")
        XCTAssertEqual(vm.userAgents.map(\.label), ["com.user.keep"], "Lists reload after removal")
        XCTAssertEqual(vm.phase, .ready)
    }

    /// System daemons are protected even if their id reaches the batch remove:
    /// the view-model only deletes user agents, never the privileged domain.
    func test_removeSelected_skipsSystemAgentsEvenWhenSelected() async {
        let removeCalled = TestBox(false)
        let systemDaemon = Self.agent(label: "com.apple.important", domain: .system)
        let vm = makeViewModel(
            loadSystemAgents: { [systemDaemon] },
            removeAgent: { _ in removeCalled.value = true }
        )
        await vm.refresh()

        await vm.removeSelected(loginItemIDs: [], agentIDs: [systemDaemon.id])

        XCTAssertFalse(removeCalled.value, "System daemons must never be removed")
        XCTAssertEqual(vm.systemAgents.map(\.label), ["com.apple.important"])
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_removeSelected_failureTransitionsToFailed() async {
        struct Boom: Error {}
        let doomed = Self.agent(label: "com.user.doomed", domain: .user)
        let vm = makeViewModel(
            loadUserAgents: { [doomed] },
            removeAgent: { _ in throw Boom() }
        )
        await vm.refresh()

        await vm.removeSelected(loginItemIDs: [], agentIDs: [doomed.id])

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Helpers

    private func makeViewModel(
        loadLoginItems: @escaping PerformanceViewModel.LoadLoginItems = { [] },
        loadUserAgents: @escaping PerformanceViewModel.LoadAgents = { [] },
        loadSystemAgents: @escaping PerformanceViewModel.LoadAgents = { [] },
        readMemory: @escaping PerformanceViewModel.ReadMemory = { .empty },
        setLoginItemEnabled: @escaping PerformanceViewModel.SetLoginItemEnabled = { _, _ in },
        openLoginItemsSettings: @escaping PerformanceViewModel.OpenLoginItemsSettings = {},
        disableAgent: @escaping PerformanceViewModel.DisableAgent = { _ in },
        enableAgent: @escaping PerformanceViewModel.EnableAgent = { _ in },
        removeAgent: @escaping PerformanceViewModel.RemoveAgent = { _ in },
        flushRAM: @escaping PerformanceViewModel.FlushRAM = {},
        runMaintenance: @escaping PerformanceViewModel.RunMaintenance = { "" },
        flushDNS: @escaping PerformanceViewModel.RunTask = { "" },
        reindexSpotlight: @escaping PerformanceViewModel.RunTask = { "" },
        thinSnapshots: @escaping PerformanceViewModel.RunTask = { "" },
        speedUpMail: @escaping PerformanceViewModel.RunTask = { "" },
        readSnapshotCount: @escaping PerformanceViewModel.ReadSnapshotCount = { 0 },
        runLog: MaintenanceRunLog? = nil,
        maintenanceScriptsAvailable: Bool = true,
        launchAtLoginChanges: AnyPublisher<Void, Never>? = nil
    ) -> PerformanceViewModel {
        // Default to an isolated, empty UserDefaults suite so the run log never
        // touches `.standard` or leaks state between tests.
        let isolatedLog = runLog ?? MaintenanceRunLog(
            defaults: UserDefaults(suiteName: "PerformanceViewModelTests.\(UUID().uuidString)")!
        )
        return PerformanceViewModel(
            loadLoginItems: loadLoginItems,
            loadUserAgents: loadUserAgents,
            loadSystemAgents: loadSystemAgents,
            readMemory: readMemory,
            setLoginItemEnabled: setLoginItemEnabled,
            openLoginItemsSettings: openLoginItemsSettings,
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

    nonisolated private static func task(_ kind: MaintenanceTask.Kind) -> MaintenanceTask {
        MaintenanceTask.catalog.first { $0.kind == kind }!
    }

    nonisolated private static func recommendation(_ kind: PerformanceRecommendation.Kind) -> PerformanceRecommendation {
        PerformanceRecommendation(
            kind: kind, title: "", detail: "", icon: "", actionLabel: "", isHero: kind == .freeUpRAM
        )
    }

    nonisolated private static func loginItem(name: String) -> LoginItem {
        LoginItem(id: name, name: name, isEnabled: true)
    }

    nonisolated private static func agent(
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
