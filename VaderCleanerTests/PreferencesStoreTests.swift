// PreferencesStoreTests.swift
// Tests that PreferencesStore exposes spec defaults and persists changes through an injected UserDefaults.

import XCTest
@testable import VaderCleaner

@MainActor
final class PreferencesStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Each test gets its own UserDefaults suite so reads/writes never
        // touch the host machine's real .standard defaults and tests cannot
        // observe each other's state.
        suiteName = "VaderCleanerTests.PreferencesStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
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

        let reader = PreferencesStore(defaults: defaults)
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

    func test_restoreDefaults_reappliesLaunchAtLoginThroughHandler() {
        var received: [Bool] = []
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.append($0) }
        )
        sut.launchAtLogin = false
        received.removeAll()

        sut.restoreDefaults()

        // Restoring flips launchAtLogin back to its default and reconciles the
        // login item through the same handler a manual toggle uses.
        XCTAssertEqual(sut.launchAtLogin, PreferencesStore.defaultLaunchAtLogin)
        XCTAssertEqual(received, [PreferencesStore.defaultLaunchAtLogin])
    }

    // MARK: - Launch-at-login wiring

    func test_didSet_invokesLaunchAtLoginHandler() {
        // Each handler invocation appends the value it received so we can
        // assert on both the initial reconcile and the user-driven toggle.
        var received: [Bool] = []
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.append($0) }
        )

        // The reconcile in init runs before the test mutates anything, so we
        // clear the captured values to focus the assertion on the didSet.
        received.removeAll()

        sut.launchAtLogin = false

        XCTAssertEqual(received, [false])
    }

    func test_handlerThrows_invokesErrorReporter() {
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
        reported.removeAll()
        sut.launchAtLogin = !sut.launchAtLogin

        XCTAssertEqual(reported, [StubError()])
    }

    func test_init_reconcilesLaunchAtLogin_whenHandlerProvided() {
        // Persist a non-default value first so we can assert that the
        // reconcile pushes the *persisted* state, not the spec default.
        defaults.set(false, forKey: "preferences.launchAtLogin")

        var received: [Bool] = []
        _ = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.append($0) }
        )

        XCTAssertEqual(received, [false])
    }

    // MARK: - Inline launch-at-login entry point

    func test_setLaunchAtLogin_appliesHandlerOnceAndPersists() throws {
        var received: [Bool] = []
        let sut = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: { received.append($0) }
        )
        // Drop the init reconcile so the assertion counts only this call.
        received.removeAll()

        try sut.setLaunchAtLogin(false)

        // Exactly one SMAppService write per change — the issue #65 single-path
        // invariant — even though the tracked value is updated and persisted too.
        XCTAssertEqual(received, [false])
        XCTAssertFalse(sut.launchAtLogin)

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.launchAtLogin)
    }

    func test_setLaunchAtLogin_rethrowsHandlerErrorWithoutReporting() {
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
        reported.removeAll()

        // Unlike the property setter — which routes failures to the global
        // alert reporter — this entry point rethrows so a caller with its own
        // inline failure UI (the Performance row) can surface the error
        // without double-reporting it.
        XCTAssertThrowsError(try sut.setLaunchAtLogin(!sut.launchAtLogin))
        XCTAssertTrue(reported.isEmpty)
    }

    func test_init_skipsReconcile_whenHandlerNil() {
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
        _ = PreferencesStore(
            defaults: defaults,
            launchAtLoginHandler: nil,
            launchAtLoginErrorReporter: { _ in reporterCalled = true }
        )

        XCTAssertFalse(reporterCalled)
    }
}
