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
        XCTAssertEqual(sut.diskSpaceThresholdPercent, 10.0, accuracy: 0.001)
        XCTAssertTrue(sut.launchAtLogin)
        XCTAssertTrue(sut.showMenuBar)
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
        writer.diskSpaceThresholdPercent = 25.0

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reader.diskSpaceThresholdPercent, 25.0, accuracy: 0.001)
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
