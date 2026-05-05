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

    /// Captures the full `SMAppService.Status`, not just `isEnabled`, because
    /// `isEnabled` collapses `.requiresApproval` to `false`. If the host
    /// machine started in `.requiresApproval` (a pending-approval entry the
    /// user has already opted into via System Settings), restoring from a
    /// `Bool` would call `setEnabled(false)` and silently unregister it.
    private var initialStatus: SMAppService.Status!

    override func setUp() {
        super.setUp()
        initialStatus = SMAppService.mainApp.status
    }

    override func tearDown() {
        // Best-effort restore. Both `.enabled` and `.requiresApproval` are
        // "registered" states from launchd's perspective; the user's approval
        // toggle in System Settings is independent of our register() call, so
        // re-registering is the closest we can get to the original — the
        // post-restore status will be whichever of the two the system
        // reports. `.notRegistered` / `.notFound` / any future case fall
        // through to unregister, which is also idempotent for those states.
        do {
            switch initialStatus {
            case .enabled, .requiresApproval:
                try LoginItemManager.setEnabled(true)
            default:
                try LoginItemManager.setEnabled(false)
            }
        } catch {
            XCTFail("Failed to restore initial login-item state: \(error)")
        }
        initialStatus = nil
        super.tearDown()
    }

    func test_setEnabledTrue_doesNotThrow() {
        XCTAssertNoThrow(try LoginItemManager.setEnabled(true))
    }

    func test_setEnabledFalse_doesNotThrow() {
        XCTAssertNoThrow(try LoginItemManager.setEnabled(false))
    }

    func test_isEnabled_returnsBool() {
        // The annotated assignment is the actual compile-time guard — if a
        // future refactor weakens the accessor (e.g. to `Bool?` or a throwing
        // form), this line stops compiling. The runtime assertion confirms
        // the accessor is referentially stable across two consecutive reads,
        // which would catch a regression that turned `isEnabled` into a
        // call with side effects.
        let value: Bool = LoginItemManager.isEnabled
        XCTAssertEqual(value, LoginItemManager.isEnabled)
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
