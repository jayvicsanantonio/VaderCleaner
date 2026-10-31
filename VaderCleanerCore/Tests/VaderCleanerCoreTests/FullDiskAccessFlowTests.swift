// FullDiskAccessFlowTests.swift
// Tests the journey to System Settings and back: when each surface offers a relaunch, and that relaunching only quits this process once a replacement has launched.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite
struct AppStateFullDiskAccessFlowTests {

    @Test func opening_settings_invokesTheInjectedAction() {
        let opened = TestBox(0)
        let sut = AppState(
            checker: { false },
            openFullDiskAccessSettings: { opened.value += 1 },
            relaunch: {}
        )
        sut.openFullDiskAccessSettings()
        #expect(opened.value == 1)
    }

    @Test func relaunch_invokesTheInjectedAction() {
        let relaunched = TestBox(0)
        let sut = AppState(
            checker: { false },
            openFullDiskAccessSettings: {},
            relaunch: { relaunched.value += 1 }
        )
        sut.relaunch()
        #expect(relaunched.value == 1)
    }

    @Test func isNotAwaitingRelaunch_beforeVisitingSettings() {
        // Offering a relaunch to someone who hasn't been to Settings yet would
        // promise a fix it can't deliver.
        let sut = AppState(checker: { false }, openFullDiskAccessSettings: {}, relaunch: {})
        #expect(!sut.isAwaitingRelaunchForFullDiskAccess)
    }

    @Test func isAwaitingRelaunch_afterVisitingSettings_whileAccessStillReadsFalse() {
        let sut = AppState(checker: { false }, openFullDiskAccessSettings: {}, relaunch: {})
        sut.openFullDiskAccessSettings()
        #expect(sut.isAwaitingRelaunchForFullDiskAccess)
    }

    @Test func isNotAwaitingRelaunch_onceAGrantAppliesWithoutARestart() {
        let hasAccess = TestBox(false)
        let sut = AppState(checker: { hasAccess.value }, openFullDiskAccessSettings: {}, relaunch: {})
        sut.openFullDiskAccessSettings()

        hasAccess.value = true
        sut.refresh()

        #expect(!sut.isAwaitingRelaunchForFullDiskAccess)
    }
}

@MainActor
@Suite
struct WelcomeFullDiskAccessFlowTests {

    private func makeSUT(relaunch: @escaping () -> Void = {}) throws -> WelcomeViewModel {
        let defaults = try #require(UserDefaults(suiteName: "VaderCleanerTests.WelcomeFlow.\(UUID().uuidString)"))
        // See WelcomeStoreTests: NSArgumentDomain outranks an isolated suite.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        return WelcomeViewModel(
            store: WelcomeStore(defaults: defaults),
            fullDiskAccessChecker: { false },
            openSystemSettings: {},
            relaunch: relaunch
        )
    }

    @Test func offersRelaunch_onlyAfterVisitingSettings() throws {
        let sut = try makeSUT()
        #expect(!sut.isAwaitingRelaunch)
        sut.requestFullDiskAccess()
        #expect(sut.isAwaitingRelaunch)
    }

    @Test func relaunch_invokesTheInjectedAction() throws {
        let relaunched = TestBox(0)
        let sut = try makeSUT(relaunch: { relaunched.value += 1 })
        sut.relaunch()
        #expect(relaunched.value == 1)
    }
}

@MainActor
@Suite
struct AppRelauncherTests {

    private struct LaunchFailed: Error {}

    @Test func quitsThisInstance_onceTheReplacementHasLaunched() async {
        let events = TestBox<[String]>([])
        await AppRelauncher.relaunch(
            openNewInstance: { events.value.append("open") },
            terminate: { events.value.append("terminate") }
        )
        #expect(events.value == ["open", "terminate"])
    }

    @Test func staysRunning_whenTheReplacementFailsToLaunch() async {
        // Quitting anyway would leave the user with no app at all.
        let terminated = TestBox(false)
        await AppRelauncher.relaunch(
            openNewInstance: { throw LaunchFailed() },
            terminate: { terminated.value = true }
        )
        #expect(!terminated.value)
    }
}

@Suite
struct SettingsFullDiskAccessRelaunchTests {

    @Test func awaitingRelaunch_offersARelaunchInsteadOfSettings() {
        let waiting = SettingsAccessStatus.fullDiskAccess(hasAccess: false, isAwaitingRelaunch: true)
        let denied = SettingsAccessStatus.fullDiskAccess(hasAccess: false)

        #expect(!waiting.isHealthy)
        #expect(waiting.actionTitle != nil)
        #expect(waiting.actionTitle != denied.actionTitle)
        #expect(waiting.detail != denied.detail)
    }

    @Test func grantedAccess_winsOverAStaleRelaunchFlag() {
        let status = SettingsAccessStatus.fullDiskAccess(hasAccess: true, isAwaitingRelaunch: true)
        #expect(status.isHealthy)
        #expect(status.actionTitle == nil)
    }
}
