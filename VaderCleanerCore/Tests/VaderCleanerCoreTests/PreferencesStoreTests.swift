// PreferencesStoreTests.swift
// Tests that PreferencesStore exposes spec defaults and persists changes through an injected UserDefaults.

import Foundation
import Testing
import XCTest
@testable import VaderCleanerCore

@MainActor
final class PreferencesStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        // Each test gets its own UserDefaults suite so reads/writes never
        // touch the host machine's real .standard defaults and tests cannot
        // observe each other's state.
        suiteName = "VaderCleanerTests.PreferencesStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Defaults

    func test_defaults_matchSpec() {
        let sut = PreferencesStore(defaults: defaults)

        XCTAssertTrue(sut.notifyLowDisk)
        XCTAssertTrue(sut.notifyHighRAM)
        XCTAssertTrue(sut.notifyMalwareFound)
        XCTAssertTrue(sut.notifyLargeFilesFound)
        XCTAssertEqual(sut.diskFreeThresholdGB, 10)
        XCTAssertTrue(sut.launchAtLogin)
        XCTAssertTrue(sut.showMenuBar)
        XCTAssertFalse(sut.menuBarShowsReading)
        // Notifications pane parity defaults — every row ships enabled.
        XCTAssertTrue(sut.remindSmartCare)
        XCTAssertEqual(sut.smartCareFrequency, .weekly)
        XCTAssertTrue(sut.notifyTrashSize)
        XCTAssertEqual(sut.trashSizeThresholdGB, 2)
        XCTAssertTrue(sut.notifyDeviceBatteryLow)
        XCTAssertTrue(sut.notifyDriveConnected)
        XCTAssertTrue(sut.notifyOverfilledDrives)
        XCTAssertTrue(sut.offerUninstallOnTrash)
        XCTAssertTrue(sut.notifyHungApps)
        XCTAssertTrue(sut.notifyAppUpdates)
        XCTAssertTrue(sut.notifyDefinitionsStale)
        // Sounds ship on, matching the banners' previous unconditional
        // `.default` sound — turning them off is the new choice, not the new
        // default.
        XCTAssertTrue(sut.notificationSoundsEnabled)
    }

    // MARK: - Persistence

    func test_persistsBoolValueAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.notifyLowDisk = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.notifyLowDisk)
    }

    func test_persistsThresholdAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.diskFreeThresholdGB = 25

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reader.diskFreeThresholdGB, 25)
    }

    func test_persistsNotificationPaneSettingsAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.remindSmartCare = false
        writer.smartCareFrequency = .monthly
        writer.notifyTrashSize = false
        writer.trashSizeThresholdGB = 5
        writer.notifyDeviceBatteryLow = false
        writer.notifyDriveConnected = false
        writer.notifyOverfilledDrives = false
        writer.offerUninstallOnTrash = false
        writer.notifyHungApps = false
        writer.notifyAppUpdates = false
        writer.notifyDefinitionsStale = false
        writer.notificationSoundsEnabled = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.notifyAppUpdates)
        XCTAssertFalse(reader.notifyDefinitionsStale)
        XCTAssertFalse(reader.notificationSoundsEnabled)
        XCTAssertFalse(reader.remindSmartCare)
        XCTAssertEqual(reader.smartCareFrequency, .monthly)
        XCTAssertFalse(reader.notifyTrashSize)
        XCTAssertEqual(reader.trashSizeThresholdGB, 5)
        XCTAssertFalse(reader.notifyDeviceBatteryLow)
        XCTAssertFalse(reader.notifyDriveConnected)
        XCTAssertFalse(reader.notifyOverfilledDrives)
        XCTAssertFalse(reader.offerUninstallOnTrash)
        XCTAssertFalse(reader.notifyHungApps)
    }

    func test_persistsAllNotificationToggles() {
        let writer = PreferencesStore(defaults: defaults)
        writer.notifyLowDisk = false
        writer.notifyHighRAM = false
        writer.notifyMalwareFound = false
        writer.notifyLargeFilesFound = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.notifyLowDisk)
        XCTAssertFalse(reader.notifyHighRAM)
        XCTAssertFalse(reader.notifyMalwareFound)
        XCTAssertFalse(reader.notifyLargeFilesFound)
    }

    func test_persistsLaunchAndMenuBarToggles() {
        let writer = PreferencesStore(defaults: defaults)
        writer.launchAtLogin = false
        writer.showMenuBar = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.launchAtLogin)
        XCTAssertFalse(reader.showMenuBar)
    }

    func test_persistsMenuBarShowsReading() {
        let writer = PreferencesStore(defaults: defaults)
        writer.menuBarShowsReading = true

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertTrue(reader.menuBarShowsReading)
    }

    // MARK: - Restore defaults

    func test_restoreDefaults_resetsEveryPreferenceToSpec() {
        let sut = PreferencesStore(defaults: defaults)
        // Flip every tracked property away from its default.
        sut.notifyLowDisk = false
        sut.notifyHighRAM = false
        sut.notifyMalwareFound = false
        sut.notifyLargeFilesFound = false
        sut.diskFreeThresholdGB = 200
        sut.remindSmartCare = false
        sut.notifyScanFinished = false
        sut.smartCareFrequency = .monthly
        sut.notifyTrashSize = false
        sut.trashSizeThresholdGB = 20
        sut.notifyDeviceBatteryLow = false
        sut.notifyDriveConnected = false
        sut.notifyOverfilledDrives = false
        sut.offerUninstallOnTrash = false
        sut.notifyHungApps = false
        sut.notifyAppUpdates = false
        sut.notifyDefinitionsStale = false
        sut.notificationSoundsEnabled = false
        sut.showMenuBar = false
        sut.menuBarShowsReading = true

        sut.restoreDefaults()

        XCTAssertEqual(sut.notifyLowDisk, PreferencesStore.defaultNotifyLowDisk)
        XCTAssertEqual(sut.notifyHighRAM, PreferencesStore.defaultNotifyHighRAM)
        XCTAssertEqual(sut.notifyMalwareFound, PreferencesStore.defaultNotifyMalwareFound)
        XCTAssertEqual(sut.notifyLargeFilesFound, PreferencesStore.defaultNotifyLargeFilesFound)
        XCTAssertEqual(sut.diskFreeThresholdGB, PreferencesStore.defaultDiskFreeThresholdGB)
        XCTAssertEqual(sut.remindSmartCare, PreferencesStore.defaultRemindSmartCare)
        XCTAssertEqual(sut.notifyScanFinished, PreferencesStore.defaultNotifyScanFinished)
        XCTAssertEqual(sut.smartCareFrequency, PreferencesStore.defaultSmartCareFrequency)
        XCTAssertEqual(sut.notifyTrashSize, PreferencesStore.defaultNotifyTrashSize)
        XCTAssertEqual(sut.trashSizeThresholdGB, PreferencesStore.defaultTrashSizeThresholdGB)
        XCTAssertEqual(sut.notifyDeviceBatteryLow, PreferencesStore.defaultNotifyDeviceBatteryLow)
        XCTAssertEqual(sut.notifyDriveConnected, PreferencesStore.defaultNotifyDriveConnected)
        XCTAssertEqual(sut.notifyOverfilledDrives, PreferencesStore.defaultNotifyOverfilledDrives)
        XCTAssertEqual(sut.offerUninstallOnTrash, PreferencesStore.defaultOfferUninstallOnTrash)
        XCTAssertEqual(sut.notifyHungApps, PreferencesStore.defaultNotifyHungApps)
        XCTAssertEqual(sut.notifyAppUpdates, PreferencesStore.defaultNotifyAppUpdates)
        XCTAssertEqual(sut.notifyDefinitionsStale, PreferencesStore.defaultNotifyDefinitionsStale)
        XCTAssertEqual(sut.notificationSoundsEnabled, PreferencesStore.defaultNotificationSoundsEnabled)
        XCTAssertEqual(sut.showMenuBar, PreferencesStore.defaultShowMenuBar)
        XCTAssertEqual(sut.menuBarShowsReading, PreferencesStore.defaultMenuBarShowsReading)
    }

    func test_restoreDefaults_persistsAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.notifyLowDisk = false
        writer.trashSizeThresholdGB = 20

        writer.restoreDefaults()

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reader.notifyLowDisk, PreferencesStore.defaultNotifyLowDisk)
        XCTAssertEqual(reader.trashSizeThresholdGB, PreferencesStore.defaultTrashSizeThresholdGB)
    }

    func test_restoreDefaults_reappliesLaunchAtLoginThroughHandler() async {
        let received = TestBox<[Bool]>([])
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.value.append($0) }
        )
        sut.launchAtLogin = false
        await sut.waitForLaunchAtLoginWrites()
        received.value.removeAll()

        sut.restoreDefaults()
        await sut.waitForLaunchAtLoginWrites()

        // Restoring flips launchAtLogin back to its default and reconciles the
        // login item through the same handler a manual toggle uses.
        XCTAssertEqual(sut.launchAtLogin, PreferencesStore.defaultLaunchAtLogin)
        XCTAssertEqual(received.value, [PreferencesStore.defaultLaunchAtLogin])
    }

    // MARK: - Launch-at-login wiring

    func test_didSet_invokesLaunchAtLoginHandler() async {
        // Each handler invocation appends the value it received so we can
        // assert on both the initial reconcile and the user-driven toggle.
        let received = TestBox<[Bool]>([])
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.value.append($0) }
        )

        // The reconcile in init runs before the test mutates anything, so we
        // clear the captured values to focus the assertion on the didSet.
        await sut.waitForLaunchAtLoginWrites()
        received.value.removeAll()

        sut.launchAtLogin = false
        await sut.waitForLaunchAtLoginWrites()

        XCTAssertEqual(received.value, [false])
    }

    func test_handlerThrows_invokesErrorReporter() async {
        struct StubError: Error, Equatable {}
        var reported: [StubError] = []
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { _ in throw StubError() },
            launchAtLoginErrorReporter: { error in
                if let stub = error as? StubError {
                    reported.append(stub)
                }
            }
        )

        // The init reconcile already throws once because the handler always
        // throws. Reset, then exercise the didSet path explicitly so the
        // assertion covers the user-driven toggle, not the reconcile path.
        await sut.waitForLaunchAtLoginWrites()
        reported.removeAll()
        sut.launchAtLogin.toggle()
        await sut.waitForLaunchAtLoginWrites()

        XCTAssertEqual(reported, [StubError()])
    }

    func test_init_reconcilesLaunchAtLogin_whenHandlerProvided() async {
        // Persist a non-default value first so we can assert that the
        // reconcile pushes the *persisted* state, not the spec default.
        defaults.set(false, forKey: "preferences.launchAtLogin")

        let received = TestBox<[Bool]>([])
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.value.append($0) }
        )
        await sut.waitForLaunchAtLoginWrites()

        XCTAssertEqual(received.value, [false])
    }

    // MARK: - Inline launch-at-login entry point

    func test_setLaunchAtLogin_appliesHandlerOnceAndPersists() async throws {
        let received = TestBox<[Bool]>([])
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.value.append($0) }
        )
        // Drop the init reconcile so the assertion counts only this call.
        await sut.waitForLaunchAtLoginWrites()
        received.value.removeAll()

        try await sut.setLaunchAtLogin(false)

        // Exactly one SMAppService write per change — the issue #65 single-path
        // invariant — even though the tracked value is updated and persisted too.
        XCTAssertEqual(received.value, [false])
        XCTAssertFalse(sut.launchAtLogin)

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.launchAtLogin)
    }

    func test_setLaunchAtLogin_rethrowsHandlerErrorWithoutReporting() async {
        struct StubError: Error, Equatable {}
        var reported: [StubError] = []
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { _ in throw StubError() },
            launchAtLoginErrorReporter: { error in
                if let stub = error as? StubError { reported.append(stub) }
            }
        )
        // Drop the init reconcile's throw before exercising the entry point.
        await sut.waitForLaunchAtLoginWrites()
        reported.removeAll()

        // Unlike the property setter — which routes failures to the global
        // alert reporter — this entry point rethrows so a caller with its own
        // inline failure UI (the Performance row) can surface the error
        // without double-reporting it.
        do {
            try await sut.setLaunchAtLogin(!sut.launchAtLogin)
            XCTFail("Expected the handler's error to be rethrown")
        } catch {
            XCTAssertTrue(error is StubError)
        }
        XCTAssertTrue(reported.isEmpty)
    }

    func test_init_skipsReconcile_whenHandlerNil() async {
        // Pins the nil-handler contract that all the other PreferencesStore
        // tests depend on: constructing the store with no handler must not
        // attempt any side effect, even when the persisted preference would
        // otherwise drive a reconcile call.
        //
        // We can't directly assert that "no handler was called" — there is no
        // handler to observe. Instead we assert through the *reporter*: if
        // the implementation ever started feeding the persisted value into
        // some other side-effect path that bypassed the nil handler, we'd
        // expect it to also surface errors through the reporter. With both
        // hooks nil, neither path can fire, and the only thing left to
        // verify is that init returns without crashing — which the test
        // implicitly covers by reaching the end.
        defaults.set(true, forKey: "preferences.launchAtLogin")

        var reporterCalled = false
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: nil,
            launchAtLoginErrorReporter: { _ in reporterCalled = true }
        )
        await sut.waitForLaunchAtLoginWrites()

        XCTAssertFalse(reporterCalled)
    }

    /// A failed `SMAppService` write must not leave the model claiming a state
    /// launchd never reached. Without the revert the wrong value is persisted
    /// too, so `init`'s reconcile re-attempts it — and re-alerts — on every
    /// launch, with no way to clear it from the Settings toggle.
    func test_launchAtLoginToggle_revertsWhenTheHandlerFails() async {
        struct StubError: Error {}
        // The handler is `@Sendable`, so its switch has to live in a box rather
        // than a captured local.
        let shouldThrow = TestBox(false)
        var reportCount = 0
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { _ in if shouldThrow.value { throw StubError() } },
            launchAtLoginErrorReporter: { _ in reportCount += 1 }
        )
        // Establish a known-good starting point through the succeeding handler.
        sut.launchAtLogin = true
        await sut.waitForLaunchAtLoginWrites()
        shouldThrow.value = true

        sut.launchAtLogin = false
        await sut.waitForLaunchAtLoginWrites()

        XCTAssertTrue(sut.launchAtLogin, "a failed apply must leave the previous value standing")
        XCTAssertEqual(reportCount, 1, "the failure is reported exactly once, not once per revert")
        XCTAssertTrue(
            PreferencesStore(defaults: defaults).launchAtLogin,
            "the reverted value is what persists, so the next launch reconciles the state that works"
        )
    }

    /// The reconcile in `init` has no previous value to fall back to — the
    /// persisted preference is the only candidate — so it reports and leaves
    /// the stored choice alone rather than inventing the opposite.
    func test_initReconcileFailure_leavesThePersistedValueAlone() async {
        struct StubError: Error {}
        defaults.set(true, forKey: "preferences.launchAtLogin")

        var reportCount = 0
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { _ in throw StubError() },
            launchAtLoginErrorReporter: { _ in reportCount += 1 }
        )
        await sut.waitForLaunchAtLoginWrites()

        XCTAssertTrue(sut.launchAtLogin)
        XCTAssertEqual(reportCount, 1)
    }

    // MARK: - Menu bar presence normalization

    /// `showMenuBar` + `keepDockIcon` model a three-way picker in which
    /// "neither" is unreachable. A hand-edited defaults file can still hold it,
    /// and the getter reports `.dockOnly` for it — so picking Dock in the
    /// picker is a no-op and the state can never be corrected from the UI.
    /// Normalizing once at init makes the reported presence true.
    func test_init_normalizesNeitherMenuBarNorDockIcon() {
        defaults.set(false, forKey: "preferences.showMenuBar")
        defaults.set(false, forKey: "preferences.keepDockIcon")

        let sut = PreferencesStore(defaults: defaults)

        XCTAssertEqual(sut.menuBarPresence, .dockOnly)
        XCTAssertTrue(sut.keepDockIcon, "the reported presence must match the model it is derived from")
        XCTAssertTrue(
            PreferencesStore(defaults: defaults).keepDockIcon,
            "the normalization persists, so the Dock icon survives the next launch"
        )
    }

    func test_init_leavesEveryReachablePresenceAlone() {
        for presence in MenuBarPresence.allCases {
            let writer = PreferencesStore(defaults: defaults)
            writer.menuBarPresence = presence

            XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarPresence, presence)
        }
    }

    // MARK: - Live stats cadence

    /// The refresh cadence has to reach `SystemStatsService` from wherever it
    /// changes — the Menu Bar picker *and* Restore Defaults, which fires from
    /// the General tab. Routing it through an injected handler is what makes
    /// the second path work.
    func test_statsUpdateInterval_appliesThroughHandler() {
        var applied: [Double] = []
        let sut = PreferencesStore(
            defaults: defaults,
            statsUpdateIntervalHandler: { applied.append($0) }
        )

        sut.statsUpdateInterval = 10

        XCTAssertEqual(applied, [10])
    }

    func test_restoreDefaults_reappliesStatsIntervalThroughHandler() {
        var applied: [Double] = []
        let sut = PreferencesStore(
            defaults: defaults,
            statsUpdateIntervalHandler: { applied.append($0) }
        )
        sut.statsUpdateInterval = 10
        applied.removeAll()

        sut.restoreDefaults()

        XCTAssertEqual(applied, [PreferencesStore.defaultStatsUpdateInterval])
    }

    /// Reads the persisted cadence without building the store, so
    /// `SystemStatsService` can be constructed before the store that will
    /// push later changes into it.
    func test_statsUpdateInterval_readableWithoutAStore() {
        XCTAssertEqual(
            PreferencesStore.statsUpdateInterval(in: defaults),
            PreferencesStore.defaultStatsUpdateInterval
        )

        PreferencesStore(defaults: defaults).statsUpdateInterval = 5

        XCTAssertEqual(PreferencesStore.statsUpdateInterval(in: defaults), 5)
    }
}

/// `SMAppService.register()` and `unregister()` block until launchd answers,
/// so the store hands each launch-at-login write to launchd off the main
/// actor. These pin what that must not cost: the toggle and the alert behave
/// as they did when the write ran inline, writes reach launchd one at a time
/// and in order, and a change made while one is in flight is never lost.
@MainActor
@Suite
final class PreferencesStoreLaunchAtLoginWriteTests {

    private struct StubError: Error {}

    private let suiteName = "VaderCleanerTests.PreferencesStore.LaunchAtLoginWrites.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The toggle must not freeze the UI while launchd answers: the setter
    /// returns at once and the write runs elsewhere.
    @Test
    func aSlowWriteRunsOffTheMainActor() async {
        let gate = CallGate()
        let sut = PreferencesStore(
            defaults: defaults,
            // Only the toggle's write is slow; the launch reconcile pushes `true`.
            launchAtLoginHandler: { enabled in if !enabled { gate.hold() } }
        )
        await sut.waitForLaunchAtLoginWrites()

        sut.launchAtLogin = false

        // `pollUntil` runs on the main actor, so seeing the write held at all
        // proves the main actor is still free while launchd answers.
        #expect(await pollUntil { gate.isHolding })
        #expect(gate.heldOnMainThread == false)
        #expect(sut.launchAtLogin == false, "the toggle flips immediately, as it always has")
        gate.open()
        await sut.waitForLaunchAtLoginWrites()
        #expect(sut.launchAtLogin == false)
    }

    /// `init` runs inside `VaderCleanerApp.init()`, so a reconcile that waited
    /// on launchd would hold up the app's launch.
    @Test
    func theLaunchReconcileDoesNotHoldUpInit() async {
        let gate = CallGate()
        let sut = PreferencesStore(defaults: defaults, launchAtLoginHandler: { _ in gate.hold() })

        #expect(await pollUntil { gate.isHolding })
        #expect(gate.heldOnMainThread == false)
        gate.open()
        await sut.waitForLaunchAtLoginWrites()
    }

    @Test
    func aFailedWriteRevertsTheToggleAndReportsTheError() async {
        var reports: [any Error] = []
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { enabled in if !enabled { throw StubError() } },
            launchAtLoginErrorReporter: { reports.append($0) }
        )
        await sut.waitForLaunchAtLoginWrites()

        sut.launchAtLogin = false
        await sut.waitForLaunchAtLoginWrites()

        #expect(sut.launchAtLogin, "a failed write must leave the previous value standing")
        #expect(reports.count == 1)
        #expect(reports.first is StubError)
        #expect(PreferencesStore(defaults: defaults).launchAtLogin, "the reverted value is what persists")
    }

    @Test
    func writesReachLaunchdOneAtATimeInTheOrderTheyWereMade() async {
        let gate = CallGate()
        let written = TestBox<[Bool]>([])
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { enabled in
                written.value.append(enabled)
                // Hold the first write after the launch reconcile, so the
                // changes below are made while it is still in flight.
                if written.value.count == 2 { gate.hold() }
            }
        )
        await sut.waitForLaunchAtLoginWrites()

        sut.launchAtLogin = false
        #expect(await pollUntil { gate.isHolding })
        sut.launchAtLogin = true
        sut.launchAtLogin = false
        // Give the later writes every chance to start before the held one
        // has answered.
        let startedAlongside = await pollUntil(timeout: .milliseconds(200)) { written.value.count > 2 }
        #expect(!startedAlongside, "a write must not start while another is still waiting on launchd")
        gate.open()
        await sut.waitForLaunchAtLoginWrites()

        #expect(written.value == [true, false, true, false])
        #expect(sut.launchAtLogin == false)
    }

    /// Only the newest write decides what the toggle shows and whether the
    /// alert appears. A failure that a newer change has already superseded
    /// must neither revert the toggle over that change nor raise the alert.
    @Test
    func aSupersededFailureNeitherRevertsTheToggleNorAlerts() async {
        let gate = CallGate()
        let calls = TestBox(0)
        var reports = 0
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { _ in
                calls.value += 1
                // The first write after the launch reconcile is held, then fails.
                if calls.value == 2 {
                    gate.hold()
                    throw StubError()
                }
            },
            launchAtLoginErrorReporter: { _ in reports += 1 }
        )
        await sut.waitForLaunchAtLoginWrites()

        sut.launchAtLogin = false
        #expect(await pollUntil { gate.isHolding })
        // Back on, then off again: the newest change asks for the same value
        // as the failing write, so only its being newer keeps the failure
        // from reverting it.
        sut.launchAtLogin = true
        sut.launchAtLogin = false
        gate.open()
        await sut.waitForLaunchAtLoginWrites()

        #expect(calls.value == 4)
        #expect(sut.launchAtLogin == false)
        #expect(reports == 0)
    }

    /// When the newest write fails, the toggle goes back to what launchd last
    /// accepted, not merely to its value before that write: a superseded
    /// failure can already have made that value wrong.
    @Test
    func aFailedWriteRevertsToWhatLaunchdLastAccepted() async {
        defaults.set(false, forKey: "preferences.launchAtLogin")
        let gate = CallGate()
        let calls = TestBox(0)
        var reports = 0
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { enabled in
                calls.value += 1
                // launchd accepts the reconcile's `false` and refuses every
                // registration; the toggle's own attempt is held first.
                guard enabled else { return }
                if calls.value == 2 { gate.hold() }
                throw StubError()
            },
            launchAtLoginErrorReporter: { _ in reports += 1 }
        )
        await sut.waitForLaunchAtLoginWrites()

        sut.launchAtLogin = true
        #expect(await pollUntil { gate.isHolding })
        // Restore Defaults re-applies `true` while the toggle's write is still
        // in flight, so that newest write has `true` on both sides of it.
        sut.restoreDefaults()
        gate.open()
        await sut.waitForLaunchAtLoginWrites()

        #expect(calls.value == 3)
        #expect(sut.launchAtLogin == false)
        #expect(reports == 1)
        #expect(PreferencesStore(defaults: defaults).launchAtLogin == false)
    }

    /// The Performance row's entry point keeps the toggle where it is until
    /// launchd has answered, and its write runs off the main actor like any
    /// other — exactly once.
    @Test
    func setLaunchAtLogin_movesTheToggleOnlyOnceLaunchdHasAnswered() async throws {
        let gate = CallGate()
        let written = TestBox<[Bool]>([])
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { enabled in
                written.value.append(enabled)
                if !enabled { gate.hold() }
            }
        )
        await sut.waitForLaunchAtLoginWrites()

        let change = Task { try await sut.setLaunchAtLogin(false) }
        #expect(await pollUntil { gate.isHolding })
        #expect(gate.heldOnMainThread == false)
        #expect(sut.launchAtLogin, "the toggle waits for launchd's answer")
        gate.open()
        try await change.value

        #expect(sut.launchAtLogin == false)
        #expect(written.value == [true, false], "one write for the change, not a second one from didSet")
        #expect(PreferencesStore(defaults: defaults).launchAtLogin == false)
    }
}
