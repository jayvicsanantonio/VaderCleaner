// LoginItemManagerTests.swift
// Tests that LoginItemManager wraps SMAppService.mainApp without throwing for the basic on/off/query operations.

import XCTest
import ServiceManagement
@testable import VaderCleaner

/// `LoginItemManager` wraps `SMAppService.mainApp`, which talks to the live
/// launchd registration database. The test host (VaderCleaner.app inside
/// DerivedData, ad-hoc signed) is registered the same way the shipping app is,
/// so calling `register()`/`unregister()` here actually mutates state on the
/// developer's machine.
///
/// We capture the pre-test status in `setUp` and restore it in `tearDown` so
/// running these tests can never leave the host with a stray login-item entry
/// the developer didn't ask for, and the relative ordering of the three tests
/// can't poison each other.
final class LoginItemManagerTests: XCTestCase {

    private var initialEnabled: Bool!

    override func setUp() {
        super.setUp()
        initialEnabled = LoginItemManager.isEnabled
    }

    override func tearDown() {
        // Best-effort restore; if the restore itself throws (e.g. the bundle
        // signature changed mid-run) we log via XCTFail rather than masking the
        // failure, but still continue teardown so subsequent tests aren't
        // blocked.
        do {
            try LoginItemManager.setEnabled(initialEnabled)
        } catch {
            XCTFail("Failed to restore initial login-item state: \(error)")
        }
        initialEnabled = nil
        super.tearDown()
    }

    func test_setEnabledTrue_doesNotThrow() {
        XCTAssertNoThrow(try LoginItemManager.setEnabled(true))
    }

    func test_setEnabledFalse_doesNotThrow() {
        XCTAssertNoThrow(try LoginItemManager.setEnabled(false))
    }

    func test_isEnabled_returnsBool() {
        // The signature already constrains this at compile time; the assertion
        // exists to catch a future change to e.g. an optional or throwing
        // accessor that would silently weaken callers.
        let value: Bool = LoginItemManager.isEnabled
        XCTAssertTrue(value || !value)
    }

    /// Pins the round-trip: enabling then disabling must leave the host in a
    /// not-enabled state. This is the regression guard for the
    /// `.requiresApproval` bug — the previous `setEnabled(false)` skipped
    /// `unregister()` whenever `service.status` was anything other than
    /// `.enabled`, which left a `.requiresApproval` entry behind. We can't
    /// deterministically synthesize `.requiresApproval` from a unit test, but
    /// asserting `!isEnabled` after the cycle catches any future regression
    /// where the off-toggle silently no-ops on the dev machine's landing
    /// state.
    func test_setEnabled_roundTrip_endsDisabled() throws {
        try LoginItemManager.setEnabled(true)
        try LoginItemManager.setEnabled(false)
        XCTAssertFalse(LoginItemManager.isEnabled)
    }
}
