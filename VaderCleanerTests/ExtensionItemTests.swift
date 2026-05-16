// ExtensionItemTests.swift
// Pins the ExtensionItem value type and the ExtensionType enum — required properties, stable raw values, and display names the Extensions Manager UI sections on.

import XCTest
@testable import VaderCleaner

final class ExtensionItemTests: XCTestCase {

    // MARK: - ExtensionItem

    /// The struct must expose the properties the discovery layer and UI bind
    /// to: name, path, type, isEnabled (plus optional bundleID and size).
    func test_extensionItem_exposesRequiredProperties() {
        let url = URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.acme.agent.plist")
        let item = ExtensionItem(
            name: "Acme Agent",
            path: url,
            bundleID: "com.acme.agent",
            type: .loginItemFromApp,
            isEnabled: true,
            size: 4096
        )

        XCTAssertEqual(item.name, "Acme Agent")
        XCTAssertEqual(item.path, url)
        XCTAssertEqual(item.bundleID, "com.acme.agent")
        XCTAssertEqual(item.type, .loginItemFromApp)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.size, 4096)
    }

    /// `id` is the on-disk path so SwiftUI list identity stays stable across
    /// re-discovery passes that re-emit the same item.
    func test_extensionItem_idIsPath() {
        let url = URL(fileURLWithPath: "/Library/Mail/Bundles/Foo.mailbundle")
        let item = ExtensionItem(
            name: "Foo",
            path: url,
            bundleID: nil,
            type: .mailPlugin,
            isEnabled: false,
            size: 0
        )
        XCTAssertEqual(item.id, url)
    }

    /// bundleID is optional — Safari `.safariextz` archives and bare launch
    /// agents don't always carry one.
    func test_extensionItem_bundleIDIsOptional() {
        let item = ExtensionItem(
            name: "Legacy",
            path: URL(fileURLWithPath: "/tmp/Legacy.safariextz"),
            bundleID: nil,
            type: .safariExtension,
            isEnabled: true,
            size: 10
        )
        XCTAssertNil(item.bundleID)
    }

    // MARK: - ExtensionType

    /// All six categories the plan enumerates must be present.
    func test_extensionType_hasAllSixCases() {
        XCTAssertEqual(ExtensionType.allCases.count, 6)
        XCTAssertEqual(
            Set(ExtensionType.allCases),
            [.safariExtension, .chromeExtension, .firefoxExtension,
             .mailPlugin, .internetPlugin, .loginItemFromApp]
        )
    }

    /// Raw values are stable identifiers used for section identity /
    /// accessibility — a rename would silently break the UI grouping.
    func test_extensionType_rawValuesAreStable() {
        XCTAssertEqual(ExtensionType.safariExtension.rawValue, "safariExtension")
        XCTAssertEqual(ExtensionType.chromeExtension.rawValue, "chromeExtension")
        XCTAssertEqual(ExtensionType.firefoxExtension.rawValue, "firefoxExtension")
        XCTAssertEqual(ExtensionType.mailPlugin.rawValue, "mailPlugin")
        XCTAssertEqual(ExtensionType.internetPlugin.rawValue, "internetPlugin")
        XCTAssertEqual(ExtensionType.loginItemFromApp.rawValue, "loginItemFromApp")
    }

    /// `id` mirrors the raw value so `ForEach` over `allCases` is stable.
    func test_extensionType_idIsRawValue() {
        for type in ExtensionType.allCases {
            XCTAssertEqual(type.id, type.rawValue)
        }
    }

    /// Every case has a non-empty, human-readable section heading.
    func test_extensionType_displayNamesAreNonEmpty() {
        for type in ExtensionType.allCases {
            XCTAssertFalse(type.displayName.isEmpty,
                           "\(type.rawValue) must have a display name")
        }
    }
}
