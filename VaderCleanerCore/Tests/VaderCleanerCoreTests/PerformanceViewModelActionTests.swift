// PerformanceViewModelActionTests.swift
// Pins how the Performance view model recovers from failed actions, reloads silently, reports what is due, and refuses to start an action over a running one.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite
final class PerformanceViewModelActionTests {

    private struct Boom: Error {}

    private let suiteName = "PerformanceViewModelActionTests.\(UUID().uuidString)"
    private let runLog: MaintenanceRunLog
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        runLog = MaintenanceRunLog(defaults: defaults)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Batch remove

    @Test
    func removeSelected_attemptsEveryItemAndReloadsAfterAFailure() async {
        let bad = Self.agent("com.example.bad")
        let good = Self.agent("com.example.good")
        let removed = TestBox<[String]>([])
        let vm = makeViewModel(
            loadUserAgents: { removed.value.contains(good.label) ? [bad] : [bad, good] },
            removeAgent: { agent in
                if agent.label == bad.label { throw Boom() }
                removed.value.append(agent.label)
            }
        )
        await vm.refresh()

        await vm.removeSelected(loginItemIDs: [], agentIDs: [bad.id, good.id])

        #expect(removed.value == [good.label], "one failure must not strand the rest")
        #expect(vm.userAgents == [bad], "the list reflects what actually happened")
        guard case .failed(let message) = vm.phase else {
            Issue.record("Expected .failed, got \(vm.phase)")
            return
        }
        #expect(message.contains("1 of 2"))
    }

    @Test
    func removeSelected_reloadsAfterASingleFailure() async {
        let bad = Self.agent("com.example.bad")
        let loads = TestBox(0)
        let vm = makeViewModel(
            loadUserAgents: {
                loads.value += 1
                return [bad]
            },
            removeAgent: { _ in throw Boom() }
        )
        await vm.refresh()

        await vm.removeSelected(loginItemIDs: [], agentIDs: [bad.id])

        #expect(loads.value == 2)
    }

    @Test
    func removeSelected_isIgnoredWhileAnotherActionRuns() async {
        let agent = Self.agent("com.example.agent")
        let gate = SuspendingCallGate()
        let removals = TestBox(0)
        let vm = makeViewModel(
            loadUserAgents: { [agent] },
            removeAgent: { _ in removals.value += 1 },
            flushDNS: {
                await gate.hold()
                return "ok"
            }
        )
        await vm.refresh()
        let running = Task { await vm.run(Self.task(.flushDNS)) }
        #expect(await pollUntil { gate.isHolding })

        await vm.removeSelected(loginItemIDs: [], agentIDs: [agent.id])

        #expect(removals.value == 0)
        gate.open()
        await running.value
    }

    // MARK: - Task re-entrancy

    @Test
    func run_isIgnoredWhileAnotherActionRuns() async {
        let gate = SuspendingCallGate()
        let runs = TestBox(0)
        let vm = makeViewModel(flushDNS: {
            runs.value += 1
            await gate.hold()
            return "ok"
        })
        await vm.refresh()
        let running = Task { await vm.run(Self.task(.flushDNS)) }
        #expect(await pollUntil { gate.isHolding })

        await vm.run([Self.task(.flushDNS)])

        #expect(runs.value == 1)
        gate.open()
        await running.value
        #expect(vm.phase == .ready)
    }

    // MARK: - Failure state

    @Test
    func dismissResult_clearsTheFullDiskAccessRecovery() async {
        let agent = Self.agent("com.example.agent")
        let vm = makeViewModel(
            loadUserAgents: { [agent] },
            removeAgent: { _ in throw Boom() },
            speedUpMail: { throw MailReindexerError.fullDiskAccessRequired }
        )
        await vm.refresh()
        await vm.run(Self.task(.speedUpMail))
        #expect(vm.failureNeedsFullDiskAccess)

        vm.dismissResult()
        #expect(!vm.failureNeedsFullDiskAccess)

        await vm.removeSelected(loginItemIDs: [], agentIDs: [agent.id])
        #expect(!vm.failureNeedsFullDiskAccess, "an unrelated failure must not offer Full Disk Access")
    }

    @Test
    func run_failedRerunClearsThePreviousResult() async {
        let shouldFail = TestBox(false)
        let vm = makeViewModel(flushDNS: {
            if shouldFail.value { throw Boom() }
            return "Flushed."
        })
        await vm.refresh()
        await vm.run(Self.task(.flushDNS))
        #expect(vm.taskResults["flushDNS"] == "Flushed.")

        shouldFail.value = true
        await vm.run(Self.task(.flushDNS))

        #expect(vm.taskResults["flushDNS"] == nil)
    }

    @Test
    func run_failedRamFlushClearsThePreviousResult() async {
        let shouldFail = TestBox(false)
        let vm = makeViewModel(flushRAM: {
            if shouldFail.value { throw Boom() }
        })
        await vm.refresh()
        await vm.run(Self.task(.freeUpRAM))
        #expect(vm.taskResults["freeUpRAM"] != nil)

        shouldFail.value = true
        await vm.run(Self.task(.freeUpRAM))

        #expect(vm.taskResults["freeUpRAM"] == nil)
    }

    @Test
    func run_doesNotShowARawHelperError() async {
        let helperError = NSError(
            domain: "com.personal.VaderCleaner.helper",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/usr/bin/mdutil exited with status 1"]
        )
        let vm = makeViewModel(reindexSpotlight: { throw helperError })
        await vm.refresh()

        await vm.run(Self.task(.reindexSpotlight))

        guard case .failed(let message) = vm.phase else {
            Issue.record("Expected .failed, got \(vm.phase)")
            return
        }
        #expect(!message.contains("mdutil"))
        #expect(message.contains(Self.task(.reindexSpotlight).title))
    }

    @Test
    func run_saysAToolStillRunningIsNotAFailureOfMacOS() async {
        let vm = makeViewModel(reindexSpotlight: {
            throw HelperToolRunner.alreadyRunningError(["/usr/bin/mdutil"])
        })
        await vm.refresh()

        await vm.run(Self.task(.reindexSpotlight))

        guard case .failed(let message) = vm.phase else {
            Issue.record("Expected .failed, got \(vm.phase)")
            return
        }
        #expect(message.contains("still running"))
        #expect(!message.contains("mdutil"))
    }

    @Test
    func run_saysATimedOutTaskMayStillBeRunning() async {
        let vm = makeViewModel(reindexSpotlight: { throw HelperConnectionError.timedOut })
        await vm.refresh()

        await vm.run(Self.task(.reindexSpotlight))

        guard case .failed(let message) = vm.phase else {
            Issue.record("Expected .failed, got \(vm.phase)")
            return
        }
        #expect(message != HelperConnectionError.message)
        #expect(message.contains("still be running"))
    }

    // MARK: - What is due

    @Test
    func dueMaintenanceTaskIDs_listsAvailableCocktailTasksThatAreStale() async {
        runLog.record("flushDNS")
        let vm = makeViewModel(maintenanceScriptsAvailable: false)

        #expect(vm.dueMaintenanceTaskIDs == ["speedUpMail"])
        #expect(vm.maintenanceTasksDue == 1)
    }

    @Test
    func maintenanceCocktail_neverRecommendsErasingTheSpotlightIndex() {
        #expect(!MaintenanceTask.maintenanceCocktailKinds.contains(.reindexSpotlight))
    }

    @Test
    func run_missingFullDiskAccessStopsMailFromStayingDue() async {
        runLog.record("flushDNS")
        let vm = makeViewModel(
            speedUpMail: { throw MailReindexerError.fullDiskAccessRequired },
            maintenanceScriptsAvailable: false
        )
        await vm.refresh()

        await vm.run(Self.task(.speedUpMail))

        #expect(vm.maintenanceTasksDue == 0, "the card must not stay up for a choice the user made")
        #expect(vm.taskResults["speedUpMail"] == nil, "nothing ran, so nothing reads as done")
    }

    // MARK: - Silent reload

    @Test
    func reloadInBackground_updatesTheListsWithoutLeavingReady() async {
        let agent = Self.agent("com.example.agent")
        let installed = TestBox(true)
        let phases = TestBox<[PerformanceViewModel.Phase]>([])
        let vm = makeViewModel(loadUserAgents: { installed.value ? [agent] : [] })
        await vm.refresh()
        installed.value = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                phases.value.append(vm.phase)
                await Task.yield()
            }
        }

        await vm.reloadInBackground()
        watcher.cancel()

        #expect(vm.userAgents.isEmpty)
        #expect(phases.value.allSatisfy { $0 == .ready })
    }

    @Test
    func reloadInBackground_doesNothingBeforeTheFirstLoad() async {
        let loads = TestBox(0)
        let vm = makeViewModel(loadUserAgents: {
            loads.value += 1
            return []
        })

        await vm.reloadInBackground()

        #expect(loads.value == 0)
        #expect(vm.phase == .idle)
    }

    @Test
    func reloadInBackground_doesNothingWhileAnActionRuns() async {
        let gate = SuspendingCallGate()
        let loads = TestBox(0)
        let vm = makeViewModel(
            loadUserAgents: {
                loads.value += 1
                return []
            },
            flushDNS: {
                await gate.hold()
                return "ok"
            }
        )
        await vm.refresh()
        let running = Task { await vm.run(Self.task(.flushDNS)) }
        #expect(await pollUntil { gate.isHolding })

        await vm.reloadInBackground()

        #expect(loads.value == 1)
        gate.open()
        await running.value
        #expect(loads.value == 2, "the reload it held up runs once the action finishes")
    }

    @Test
    func reloadInBackground_heldUpByABatchRunsOnceWhenTheBatchEnds() async {
        let gate = SuspendingCallGate()
        let loads = TestBox(0)
        let vm = makeViewModel(
            loadUserAgents: {
                loads.value += 1
                return []
            },
            flushDNS: {
                await gate.hold()
                return "ok"
            }
        )
        await vm.refresh()
        let batch = Task { await vm.run([Self.task(.flushDNS), Self.task(.reindexSpotlight)]) }
        #expect(await pollUntil { gate.isHolding })

        await vm.reloadInBackground()
        gate.open()
        await batch.value

        #expect(loads.value == 2)
    }

    @Test
    func reloadInBackground_heldUpByAFailureRunsWhenItIsDismissed() async {
        let loads = TestBox(0)
        let vm = makeViewModel(
            loadUserAgents: {
                loads.value += 1
                return []
            },
            flushDNS: { throw Boom() }
        )
        await vm.refresh()
        await vm.run(Self.task(.flushDNS))

        await vm.reloadInBackground()
        #expect(loads.value == 1)

        vm.dismissResult()
        #expect(await pollUntil { loads.value == 2 })
    }

    @Test
    func reloadInBackground_coalescesCallsThatOverlap() async {
        let gate = SuspendingCallGate()
        let holdLoads = TestBox(false)
        let loads = TestBox(0)
        let vm = makeViewModel(loadUserAgents: {
            loads.value += 1
            if holdLoads.value { await gate.hold() }
            return []
        })
        await vm.refresh()
        holdLoads.value = true
        let first = Task { await vm.reloadInBackground() }
        #expect(await pollUntil { gate.isHolding })

        await vm.reloadInBackground()
        await vm.reloadInBackground()
        #expect(loads.value == 2, "overlapping calls must not start their own discovery")

        gate.open()
        await first.value
        #expect(loads.value == 3, "one more pass covers everything asked for meanwhile")
    }

    @Test
    func reloadInBackground_restartsWhenAnAgentIsToggledMidFlight() async {
        let agent = Self.agent("com.example.agent")
        let installedLater = Self.agent("com.example.installedLater")
        let gate = SuspendingCallGate()
        let holdNextLoad = TestBox(false)
        let disabled = TestBox(false)
        let vm = makeViewModel(
            loadUserAgents: {
                // A read that started before the toggle lands reports the old state.
                let current = agent.settingEnabled(!disabled.value)
                if holdNextLoad.value {
                    await gate.hold()
                    return disabled.value ? [current, installedLater] : [agent]
                }
                return [current]
            },
            disableAgent: { _ in disabled.value = true }
        )
        await vm.refresh()
        holdNextLoad.value = true
        let reload = Task { await vm.reloadInBackground() }
        #expect(await pollUntil { gate.isHolding })

        await vm.disable(agent)
        gate.open()
        await reload.value

        #expect(vm.userAgents.first?.isEnabled == false, "a stale read must not undo the toggle")
        #expect(vm.userAgents.contains(installedLater), "the discarded read is taken again")
    }

    @Test
    func reloadInBackground_expiresOldResults() async {
        let vm = makeViewModel(flushDNS: { "Flushed." })
        await vm.refresh()
        await vm.run(Self.task(.flushDNS))
        runLog.record("flushDNS", at: Date(timeIntervalSinceNow: -(MaintenanceRunLog.staleWindow + 60)))

        await vm.reloadInBackground()

        #expect(vm.taskResults["flushDNS"] == nil)
    }

    // MARK: - Loading

    @Test
    func refresh_doesNotReadMemory() async {
        let reads = TestBox(0)
        let vm = makeViewModel(readMemory: {
            reads.value += 1
            return .empty
        })

        await vm.refresh()

        #expect(reads.value == 0, "the stats service is shared, and a forced read skews its CPU delta")
    }

    // MARK: - Helpers

    private func makeViewModel(
        loadUserAgents: @escaping PerformanceViewModel.LoadAgents = { [] },
        readMemory: @escaping PerformanceViewModel.ReadMemory = { .empty },
        disableAgent: @escaping PerformanceViewModel.DisableAgent = { _ in },
        removeAgent: @escaping PerformanceViewModel.RemoveAgent = { _ in },
        flushRAM: @escaping PerformanceViewModel.FlushRAM = {},
        flushDNS: @escaping PerformanceViewModel.RunTask = { "" },
        reindexSpotlight: @escaping PerformanceViewModel.RunTask = { "" },
        speedUpMail: @escaping PerformanceViewModel.RunTask = { "" },
        maintenanceScriptsAvailable: Bool = true
    ) -> PerformanceViewModel {
        PerformanceViewModel(
            loadLoginItems: { [] },
            loadUserAgents: loadUserAgents,
            loadSystemAgents: { [] },
            readMemory: readMemory,
            setLoginItemEnabled: { _, _ in },
            disableAgent: disableAgent,
            enableAgent: { _ in },
            removeAgent: removeAgent,
            flushRAM: flushRAM,
            runMaintenance: { "" },
            flushDNS: flushDNS,
            reindexSpotlight: reindexSpotlight,
            speedUpMail: speedUpMail,
            runLog: runLog,
            maintenanceScriptsAvailable: maintenanceScriptsAvailable
        )
    }

    nonisolated private static func task(_ kind: MaintenanceTask.Kind) -> MaintenanceTask {
        MaintenanceTask.catalog.first { $0.kind == kind }!
    }

    nonisolated private static func agent(_ label: String) -> LaunchAgent {
        LaunchAgent(
            label: label,
            path: URL(fileURLWithPath: "/tmp/\(label).plist"),
            programPath: "/bin/true",
            isEnabled: true,
            domain: .user
        )
    }
}
