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

    func test_items_reflectsDisabledStatusFromProvider() {
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .notRegistered }
        )

        XCTAssertFalse(manager.items().first?.isEnabled == true)
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
