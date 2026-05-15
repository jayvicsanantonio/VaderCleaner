// UpdateInfoTests.swift
// Tests the UpdateInfo value type — identifier stability, per-install uniqueness, and the source enum used to pick which update channel a row was discovered through.

import XCTest
@testable import VaderCleaner

final class UpdateInfoTests: XCTestCase {

    /// `id` keys off the installed bundle path, so it stays stable when
    /// only the version strings change between successive checks.
    func test_id_isStableAcrossVersionChanges() {
        let url = URL(string: "https://apps.apple.com/app/id123")!
        let bundle = URL(fileURLWithPath: "/Applications/Helio.app")
        let a = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            bundleURL: bundle,
            installedVersion: "1.0.0",
            latestVersion: "1.0.1",
            source: .appStore,
            updateURL: url
        )
        let b = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            bundleURL: bundle,
            installedVersion: "1.0.1",
            latestVersion: "1.0.2",
            source: .appStore,
            updateURL: url
        )
        XCTAssertEqual(a.id, b.id)
    }

    /// The same bundle ID installed in two locations must produce two
    /// distinct identities so SwiftUI renders both rows instead of
    /// collapsing them and dropping/reusing the wrong one.
    func test_id_isUniquePerInstalledBundlePath() {
        let url = URL(string: "https://apps.apple.com/app/id123")!
        let primary = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"),
            installedVersion: "1.0.0",
            latestVersion: "2.0.0",
            source: .appStore,
            updateURL: url
        )
        let secondary = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            bundleURL: URL(fileURLWithPath: "/Users/me/Applications/Helio.app"),
            installedVersion: "1.5.0",
            latestVersion: "2.0.0",
            source: .appStore,
            updateURL: url
        )
        XCTAssertNotEqual(primary.id, secondary.id)
    }

    /// `source` carries the channel; the App Updater UI uses it to render a
    /// per-row badge ("App Store" vs "Sparkle").
    func test_sourceIsCarriedThroughInit() {
        let url = URL(string: "https://example.com/x.dmg")!
        let info = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .sparkle,
            updateURL: url
        )
        XCTAssertEqual(info.source, .sparkle)
        XCTAssertEqual(info.updateURL, url)
    }
}
