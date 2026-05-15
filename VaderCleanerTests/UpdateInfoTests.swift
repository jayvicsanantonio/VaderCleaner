// UpdateInfoTests.swift
// Tests the UpdateInfo value type — identifier stability, equality, and the source enum used to pick which update channel a row was discovered through.

import XCTest
@testable import VaderCleaner

final class UpdateInfoTests: XCTestCase {

    /// `id` keys off the bundle ID so SwiftUI lists stay stable when the
    /// version strings change between successive checks.
    func test_id_isStableAcrossVersionChanges() {
        let url = URL(string: "https://apps.apple.com/app/id123")!
        let a = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            installedVersion: "1.0.0",
            latestVersion: "1.0.1",
            source: .appStore,
            updateURL: url
        )
        let b = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            installedVersion: "1.0.1",
            latestVersion: "1.0.2",
            source: .appStore,
            updateURL: url
        )
        XCTAssertEqual(a.id, b.id)
    }

    /// `source` carries the channel; the App Updater UI uses it to render a
    /// per-row badge ("App Store" vs "Sparkle").
    func test_sourceIsCarriedThroughInit() {
        let url = URL(string: "https://example.com/x.dmg")!
        let info = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .sparkle,
            updateURL: url
        )
        XCTAssertEqual(info.source, .sparkle)
        XCTAssertEqual(info.updateURL, url)
    }
}
