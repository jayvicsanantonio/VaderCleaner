// OptimizationViewModelTests.swift
// Drives the OptimizationViewModel state machine — load, RAM flush, maintenance scripts, login-item toggle, and agent disable/remove — through injected fakes.

import XCTest
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

    // MARK: - Agent disable / remove

    func test_disableAgent_invokesCollaboratorAndReloads() async {
        var disabled: String?
        let agent = Self.agent(label: "com.user.a", domain: .user)
        let vm = makeViewModel(
            loadUserAgents: { [agent] },
            disableAgent: { disabled = $0.label }
        )
        await vm.refresh()

        await vm.disable(agent)

        XCTAssertEqual(disabled, "com.user.a")
        XCTAssertEqual(vm.phase, .ready)
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
        removeAgent: @escaping OptimizationViewModel.RemoveAgent = { _ in },
        flushRAM: @escaping OptimizationViewModel.FlushRAM = {},
        runMaintenance: @escaping OptimizationViewModel.RunMaintenance = { "" }
    ) -> OptimizationViewModel {
        OptimizationViewModel(
            loadLoginItems: loadLoginItems,
            loadUserAgents: loadUserAgents,
            loadSystemAgents: loadSystemAgents,
            readMemory: readMemory,
            setLoginItemEnabled: setLoginItemEnabled,
            disableAgent: disableAgent,
            removeAgent: removeAgent,
            flushRAM: flushRAM,
            runMaintenance: runMaintenance
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
