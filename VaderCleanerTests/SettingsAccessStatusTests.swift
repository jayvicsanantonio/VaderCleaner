// SettingsAccessStatusTests.swift
// Tests the pure mapping from Full Disk Access and helper-daemon state to the status rows shown on the General settings tab.

import XCTest
import ServiceManagement
@testable import VaderCleaner

final class SettingsAccessStatusTests: XCTestCase {

    // MARK: - Full Disk Access

    func test_fullDiskAccess_granted_isHealthy_andOffersNoAction() {
        let status = SettingsAccessStatus.fullDiskAccess(hasAccess: true)

        XCTAssertTrue(status.isHealthy)
        XCTAssertNil(status.actionTitle, "there is nothing to fix once access is granted")
        XCTAssertFalse(status.detail.isEmpty)
    }

    func test_fullDiskAccess_denied_needsAttention_andOffersAnAction() {
        let status = SettingsAccessStatus.fullDiskAccess(hasAccess: false)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle, "the user needs a way to grant access")
        XCTAssertFalse(status.detail.isEmpty)
    }

    /// The denied line has to explain the consequence, not just name the
    /// permission — that's what makes it actionable for a non-technical user.
    func test_fullDiskAccess_deniedDetail_saysWhatTheUserLosesWithoutIt() {
        let denied = SettingsAccessStatus.fullDiskAccess(hasAccess: false)
        let granted = SettingsAccessStatus.fullDiskAccess(hasAccess: true)

        XCTAssertNotEqual(denied.detail, granted.detail)
        XCTAssertTrue(
            denied.detail.lowercased().contains("miss"),
            "the denied line should say scans will miss things: \(denied.detail)"
        )
    }

    // MARK: - Helper daemon

    func test_helper_enabled_isHealthy_andOffersNoAction() {
        let status = SettingsAccessStatus.helper(status: .enabled, isReachable: true)

        XCTAssertTrue(status.isHealthy)
        XCTAssertNil(status.actionTitle)
    }

    /// A registration can read `.enabled` while the helper is unreachable — a
    /// rebuilt binary leaves the approval record behind but no running service,
    /// and every privileged call then fails. The row must not claim health it
    /// hasn't verified.
    func test_helper_enabledButUnreachable_needsAttention_andOffersRepair() {
        let status = SettingsAccessStatus.helper(status: .enabled, isReachable: false)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle, "the user needs a way to repair it")
    }

    func test_helper_enabledButUnreachable_detailDiffersFromBothWorkingAndMissing() {
        let unreachable = SettingsAccessStatus.helper(status: .enabled, isReachable: false).detail
        let working = SettingsAccessStatus.helper(status: .enabled, isReachable: true).detail
        let missing = SettingsAccessStatus.helper(status: .notRegistered, isReachable: false).detail

        XCTAssertNotEqual(unreachable, working)
        XCTAssertNotEqual(unreachable, missing, "\"installed but silent\" is not \"never installed\"")
    }

    /// Reachability only decides the `.enabled` row: the other states are
    /// unusable regardless, and probing them would say nothing new.
    func test_helper_unregistered_readsTheSameWhetherProbedOrNot() {
        XCTAssertEqual(
            SettingsAccessStatus.helper(status: .notRegistered, isReachable: true),
            SettingsAccessStatus.helper(status: .notRegistered, isReachable: false)
        )
    }

    func test_helper_requiresApproval_needsAttention_andSendsUserToApprove() {
        let status = SettingsAccessStatus.helper(status: .requiresApproval, isReachable: false)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle)
        XCTAssertTrue(
            status.detail.lowercased().contains("approve") || status.detail.lowercased().contains("approval"),
            "an approval-pending helper should tell the user to approve it: \(status.detail)"
        )
    }

    func test_helper_notRegistered_needsAttention_andOffersRepair() {
        let status = SettingsAccessStatus.helper(status: .notRegistered, isReachable: false)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle)
    }

    func test_helper_notFound_needsAttention_andOffersRepair() {
        let status = SettingsAccessStatus.helper(status: .notFound, isReachable: false)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle)
    }

    /// Every unhealthy helper state must carry a distinct explanation —
    /// "needs approval", "isn't installed", and "installed but silent" call for
    /// different user moves.
    func test_helper_unhealthyStates_haveDistinctDetails() {
        let details = [
            SettingsAccessStatus.helper(status: .requiresApproval, isReachable: false).detail,
            SettingsAccessStatus.helper(status: .notRegistered, isReachable: false).detail,
            SettingsAccessStatus.helper(status: .enabled, isReachable: false).detail,
        ]

        XCTAssertEqual(Set(details).count, details.count, "each state explains itself differently")
    }

    /// Copy for these rows is user-facing: it must never leak the API's
    /// vocabulary ("SMAppService", "daemon", "launchd") at a non-technical user.
    func test_helperCopy_avoidsSystemJargon() {
        let allStates: [SMAppService.Status] = [.enabled, .requiresApproval, .notRegistered, .notFound]
        let jargon = ["smappservice", "daemon", "launchd", "plist", "xpc"]

        for state in allStates {
            for isReachable in [true, false] {
                let detail = SettingsAccessStatus.helper(status: state, isReachable: isReachable).detail.lowercased()
                for term in jargon {
                    XCTAssertFalse(detail.contains(term), "\(state) detail leaks \"\(term)\": \(detail)")
                }
            }
        }
    }
}
