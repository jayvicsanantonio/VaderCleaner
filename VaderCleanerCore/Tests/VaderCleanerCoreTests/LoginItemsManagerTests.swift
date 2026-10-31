// LoginItemsManagerTests.swift
// Drives LoginItemsManager through an injected SMAppService status closure so no real login-item registration is touched.

import XCTest
import ServiceManagement
@testable import VaderCleanerCore

final class LoginItemsManagerTests: XCTestCase {

    func test_items_reflectsEnabledStatusFromProvider() {
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .enabled }
        )

        let items = manager.items()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "com.personal.VaderCleaner")
        XCTAssertEqual(items.first?.name, "VaderCleaner")
        XCTAssertTrue(items.first?.isEnabled == true)
        XCTAssertFalse(items.first?.requiresApproval == true)
    }

    /// A host app that isn't registered doesn't open at login, so there is
    /// nothing to report: counting it would show "1 Login Item" forever.
    func test_items_isEmptyWhenTheHostAppIsNotRegistered() {
        for status in [SMAppService.Status.notRegistered, .notFound] {
            let manager = LoginItemsManager(
                displayName: "VaderCleaner",
                identifier: "com.personal.VaderCleaner",
                statusProvider: { status }
            )

            XCTAssertEqual(manager.items(), [])
        }
    }

    func test_items_requiresApproval_readsAsEnabledAndFlagsApproval() {
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .requiresApproval }
        )

        let item = manager.items().first

        // `.requiresApproval` means launchd holds the registration but it is
        // not active until the user approves it in System Settings. The row
        // treats it as enabled — so a fresh `register()`, which lands in
        // `.requiresApproval`, doesn't snap the toggle back to off — and flags
        // it so the view can show a "finish in System Settings" hint.
        XCTAssertTrue(item?.isEnabled == true)
        XCTAssertTrue(item?.requiresApproval == true)
    }
}
