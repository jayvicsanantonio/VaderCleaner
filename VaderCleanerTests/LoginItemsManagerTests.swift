// LoginItemsManagerTests.swift
// Drives LoginItemsManager through injected SMAppService status/handler closures so no real login-item registration is touched.

import XCTest
import ServiceManagement
@testable import VaderCleaner

final class LoginItemsManagerTests: XCTestCase {

    func test_items_reflectsEnabledStatusFromProvider() {
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .enabled },
            setEnabledHandler: { _ in }
        )

        let items = manager.items()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "com.personal.VaderCleaner")
        XCTAssertEqual(items.first?.name, "VaderCleaner")
        XCTAssertTrue(items.first?.isEnabled == true)
    }

    func test_items_reflectsDisabledStatusFromProvider() {
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .notRegistered },
            setEnabledHandler: { _ in }
        )

        XCTAssertFalse(manager.items().first?.isEnabled == true)
    }

    func test_setEnabled_forwardsRequestedStateToHandler() throws {
        var received: Bool?
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .enabled },
            setEnabledHandler: { received = $0 }
        )

        let item = try XCTUnwrap(manager.items().first)
        try manager.setEnabled(false, for: item)

        XCTAssertEqual(received, false)
    }

    func test_setEnabled_propagatesHandlerError() {
        struct Boom: Error {}
        let manager = LoginItemsManager(
            displayName: "VaderCleaner",
            identifier: "com.personal.VaderCleaner",
            statusProvider: { .enabled },
            setEnabledHandler: { _ in throw Boom() }
        )

        let item = LoginItem(id: "x", name: "x", isEnabled: true)
        XCTAssertThrowsError(try manager.setEnabled(true, for: item))
    }
}
