// DashboardStartOverTests.swift
// Pins the Start Over contract the Performance and Applications dashboards share with the other sections: it returns to the intro, and it waits for anything still running.

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
        await vm.refresh()

        #expect(loads.value == 2)
        #expect(vm.phase == .ready)
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

    private func makeViewModel(
        loadLoginItems: @escaping PerformanceViewModel.LoadLoginItems = { [] },
        flushDNS: @escaping PerformanceViewModel.RunTask = { "" }
    ) -> PerformanceViewModel {
        PerformanceViewModel(
            loadLoginItems: loadLoginItems,
            loadUserAgents: { [] },
            loadSystemAgents: { [] },
            readMemory: { .empty },
            setLoginItemEnabled: { _, _ in },
            disableAgent: { _ in },
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
