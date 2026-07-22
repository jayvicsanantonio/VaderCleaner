// NotificationSettingsModelTests.swift
// Tests the Notifications settings permission row: status refresh, when the system prompt can still be raised, and the test-banner send.

import XCTest
import UserNotifications
@testable import VaderCleaner

@MainActor
final class NotificationSettingsModelTests: XCTestCase {

    private var dispatcher: StubNotificationDispatcher!

    override func setUp() {
        super.setUp()
        dispatcher = StubNotificationDispatcher()
    }

    override func tearDown() {
        dispatcher = nil
        super.tearDown()
    }

    private func makeModel(
        status: UNAuthorizationStatus,
        onRequest: (@MainActor () async -> UNAuthorizationStatus)? = nil
    ) -> NotificationSettingsModel {
        var current = status
        return NotificationSettingsModel(
            dispatcher: dispatcher,
            statusReader: { current },
            permissionRequester: {
                if let onRequest { current = await onRequest() }
            }
        )
    }

    func test_refresh_readsTheCurrentStatus() async {
        let model = makeModel(status: .denied)

        await model.refresh()

        XCTAssertEqual(model.authorizationStatus, .denied)
    }

    /// The row must render something sensible before the first async read
    /// lands, and "not determined" is the honest starting assumption.
    func test_startsNotDetermined_beforeAnyRefresh() {
        let model = makeModel(status: .authorized)

        XCTAssertEqual(model.authorizationStatus, .notDetermined)
    }

    func test_requestPermission_raisesThePromptAndAdoptsTheResult() async {
        let model = makeModel(status: .notDetermined, onRequest: { .authorized })

        await model.requestPermission()

        XCTAssertEqual(model.authorizationStatus, .authorized)
    }

    /// Once the user has denied, asking again does nothing at the system level.
    /// The model must not pretend otherwise — the view routes to System
    /// Settings instead.
    func test_requestPermission_isANoOpOnceDenied() async {
        var requested = false
        let model = NotificationSettingsModel(
            dispatcher: dispatcher,
            statusReader: { .denied },
            permissionRequester: { requested = true }
        )
        await model.refresh()

        await model.requestPermission()

        XCTAssertFalse(requested, "a denied decision can only be changed in System Settings")
    }

    func test_sendTest_dispatchesTheTestBanner() {
        let model = makeModel(status: .authorized)

        model.sendTest()

        XCTAssertEqual(dispatcher.calls, [.test])
    }

    /// The test banner is the one thing that must fire regardless of the
    /// per-alert toggles — it exists to prove delivery works.
    func test_sendTest_isNotGatedByAuthorizationState() {
        let model = makeModel(status: .denied)

        model.sendTest()

        XCTAssertEqual(dispatcher.calls, [.test])
    }
}
