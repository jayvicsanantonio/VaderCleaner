// NotificationAccessStatusTests.swift
// Tests the mapping from UNAuthorizationStatus to the permission row shown at the top of the Notifications settings tab.

import XCTest
import UserNotifications
@testable import VaderCleaner

final class NotificationAccessStatusTests: XCTestCase {

    func test_authorized_isHealthy_andOffersNoFix() {
        let status = NotificationAccessStatus.display(for: .authorized)

        XCTAssertTrue(status.isHealthy)
        XCTAssertNil(status.actionTitle)
    }

    /// Provisional authorization delivers quietly to Notification Center. That
    /// still works, so it must not be reported as broken — but the user should
    /// be told the banners are silent.
    func test_provisional_isHealthy_butSaysDeliveryIsQuiet() {
        let status = NotificationAccessStatus.display(for: .provisional)

        XCTAssertTrue(status.isHealthy)
        XCTAssertTrue(
            status.detail.lowercased().contains("quiet") ||
            status.detail.lowercased().contains("silently") ||
            status.detail.lowercased().contains("notification centre") ||
            status.detail.lowercased().contains("notification center"),
            "provisional should explain delivery is quiet: \(status.detail)"
        )
    }

    /// The whole point of the row: when permission is denied every toggle on
    /// the pane is inert, and the user has to be told that plainly.
    func test_denied_needsAttention_andSaysNothingWillArrive() {
        let status = NotificationAccessStatus.display(for: .denied)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle)
        XCTAssertTrue(
            status.detail.lowercased().contains("won't") ||
            status.detail.lowercased().contains("not"),
            "denied should say alerts won't arrive: \(status.detail)"
        )
    }

    func test_notDetermined_needsAttention_andOffersToAsk() {
        let status = NotificationAccessStatus.display(for: .notDetermined)

        XCTAssertFalse(status.isHealthy)
        XCTAssertNotNil(status.actionTitle)
    }

    /// Denied and not-determined need different user moves — one opens System
    /// Settings, the other can still raise the system prompt.
    func test_deniedAndNotDetermined_readDifferently() {
        let denied = NotificationAccessStatus.display(for: .denied)
        let undetermined = NotificationAccessStatus.display(for: .notDetermined)

        XCTAssertNotEqual(denied.detail, undetermined.detail)
    }

    /// `notDetermined` is the only state where asking the system directly can
    /// still produce a prompt; every other unhealthy state must route to
    /// System Settings instead, or the button silently does nothing.
    func test_onlyNotDetermined_canRaiseTheSystemPrompt() {
        XCTAssertTrue(NotificationAccessStatus.canRequestPermission(for: .notDetermined))
        XCTAssertFalse(NotificationAccessStatus.canRequestPermission(for: .denied))
        XCTAssertFalse(NotificationAccessStatus.canRequestPermission(for: .authorized))
        XCTAssertFalse(NotificationAccessStatus.canRequestPermission(for: .provisional))
    }

    /// Copy on this row is user-facing and must not leak the framework's
    /// vocabulary.
    func test_copy_avoidsFrameworkJargon() {
        let states: [UNAuthorizationStatus] = [.authorized, .denied, .notDetermined, .provisional]
        let jargon = ["unauthorizationstatus", "unusernotificationcenter", "provisional", "authorizationstatus"]

        for state in states {
            let detail = NotificationAccessStatus.display(for: state).detail.lowercased()
            for term in jargon {
                XCTAssertFalse(detail.contains(term), "\(state) detail leaks \"\(term)\": \(detail)")
            }
        }
    }
}
