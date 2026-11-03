// DashboardStartOverTests.swift
// Pins the Start Over contract the Performance and Applications dashboards share with the other sections: it returns to the intro, it waits for anything still running, and the reload it starts can't undo a batch uninstall.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite
struct PerformanceStartOverTests {

    @Test
    func startOver_returnsTheSectionToItsIntro() async {
        let vm = makeViewModel()
        await vm.refresh()
        #expect(vm.scanPresentation == .results)

        vm.startOver()

        #expect(vm.phase == .idle)
        #expect(vm.scanPresentation == .intro)
    }

    @Test
    func scanningAfterStartOver_loadsTheListsAgain() async {
        let loads = TestBox(0)
        let vm = makeViewModel(loadLoginItems: {
            loads.value += 1
            return []
        })
        await vm.refresh()

        vm.startOver()
        // The intro's Scan disc calls `beginScan()`, not `refresh()` directly.
        vm.beginScan()

        // A load counts when it starts and reaches `.ready` only when it ends.
        #expect(await pollUntil { loads.value == 2 && vm.phase == .ready })
    }

    @Test
    func startOver_waitsForARunningBatch() async throws {
        let gate = SuspendingCallGate()
        let vm = makeViewModel(flushDNS: {
            await gate.hold()
            return "Flushed."
        })
        await vm.refresh()
        let flushDNS = try #require(MaintenanceTask.catalog.first { $0.kind == .flushDNS })

        let batch = Task { await vm.run([flushDNS]) }
        #expect(await pollUntil { gate.isHolding })
        vm.startOver()

        #expect(vm.isRunningBatch)
        #expect(vm.scanPresentation == .results)
        gate.open()
        await batch.value
    }

    @Test
    func startOver_waitsForAnAgentToggle() async throws {
        // A toggle leaves the phase at `.ready` while it runs, and a failure it
        // then reports would pull the section back out of its intro.
        let gate = SuspendingCallGate()
        let agent = LaunchAgent(
            label: "com.user.agent",
            path: URL(fileURLWithPath: "/tmp/com.user.agent.plist"),
            programPath: "/bin/true",
            isEnabled: true,
            domain: .user
        )
        let vm = makeViewModel(
            loadUserAgents: { [agent] },
            disableAgent: { _ in await gate.hold() }
        )
        await vm.refresh()

        let toggle = Task { await vm.disable(agent) }
        #expect(await pollUntil { gate.isHolding })
        vm.startOver()

        #expect(vm.scanPresentation == .results)
        gate.open()
        await toggle.value
    }

    private func makeViewModel(
        loadLoginItems: @escaping PerformanceViewModel.LoadLoginItems = { [] },
        loadUserAgents: @escaping PerformanceViewModel.LoadAgents = { [] },
        disableAgent: @escaping PerformanceViewModel.DisableAgent = { _ in },
        flushDNS: @escaping PerformanceViewModel.RunTask = { "" }
    ) -> PerformanceViewModel {
        PerformanceViewModel(
            loadLoginItems: loadLoginItems,
            loadUserAgents: loadUserAgents,
            loadSystemAgents: { [] },
            readMemory: { .empty },
            setLoginItemEnabled: { _, _ in },
            disableAgent: disableAgent,
            enableAgent: { _ in },
            removeAgent: { _ in },
            flushRAM: {},
            runMaintenance: { "" },
            flushDNS: flushDNS,
            runLog: MaintenanceRunLog(
                defaults: UserDefaults(suiteName: "PerformanceStartOverTests.\(UUID().uuidString)")!
            )
        )
    }
}

@MainActor
@Suite
struct ApplicationsStartOverTests {

    @Test
    func isRemoving_holdsOnlyWhileARemovalIsMovingFiles() async {
        let gate = SuspendingCallGate()
        let group = LeftoverGroup(
            bundleID: "com.gone.app",
            displayName: "Gone",
            urls: [URL(fileURLWithPath: "/Users/test/Library/Application Support/com.gone.app")],
            totalBytes: 100
        )
        let vm = ApplicationsViewModel(
            discoverApps: { [] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in [group] },
            recycleFiles: { urls in
                await gate.hold()
                return Set(urls)
            },
            measureFiles: { _ in 0 }
        )
        await vm.scan()
        vm.toggleLeftover(group)
        #expect(!vm.isRemoving)

        let removal = Task { await vm.deleteSelectedLeftovers() }
        #expect(await pollUntil { gate.isHolding })
        #expect(vm.isRemoving)

        gate.open()
        await removal.value
        #expect(!vm.isRemoving)
    }
}

@MainActor
@Suite
struct UninstallerBatchReloadTests {

    private func app(_ name: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: "com.test.\(name.lowercased())",
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }

    @Test
    func aReloadThatReadTheDiskBeforeTheBatch_doesNotBringBackWhatItRemoved() async {
        let doomed = app("Doomed")
        let kept = app("Kept")
        let discoverCalls = TestBox(0)
        let discoverGate = SuspendingCallGate()
        let recycleGate = SuspendingCallGate()
        let vm = AppUninstallerViewModel(
            discover: { _ in
                discoverCalls.value += 1
                if discoverCalls.value > 1 { await discoverGate.hold() }
                return [doomed, kept]
            },
            findFiles: { _ in [] },
            recycle: { _, _ in
                await recycleGate.hold()
                return AppUninstallerViewModel.RecycleOutcome(bytesFreed: 1, bundlePermanentlyRemoved: false)
            }
        )
        await vm.loadApps()
        vm.selectAllForUninstall([doomed.id])

        let batch = Task { await vm.uninstallSelected() }
        #expect(await pollUntil { recycleGate.isHolding })
        #expect(vm.isUninstalling)
        // Start Over's refresh, reading the disk before the app is trashed.
        let reload = Task { await vm.refresh() }
        #expect(await pollUntil { discoverGate.isHolding })

        recycleGate.open()
        await batch.value
        discoverGate.open()
        await reload.value

        #expect(vm.apps.map(\.id) == [kept.id])
        #expect(vm.phase == .complete(bytesFreed: 1, permanentRemoval: false))
        #expect(!vm.isUninstalling)
    }
}
