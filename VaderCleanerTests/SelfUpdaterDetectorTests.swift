// SelfUpdaterDetectorTests.swift
// Tests the bundled-updater detection used to explain why an app carries no queryable update feed — Keystone's KSUpdateURL, an embedded Squirrel.framework, their precedence, and the absent/malformed cases.

import XCTest
@testable import VaderCleaner

final class SelfUpdaterDetectorTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempDirectory)
        tempDirectory = nil
    }

    // MARK: - Keystone

    /// `KSUpdateURL` is how Google's Omaha-based updater advertises itself.
    /// Chrome carries it and no `SUFeedURL`, which is exactly why it was
    /// invisible to the probe before coverage reporting existed.
    func test_selfUpdater_detectsKeystoneFromKSUpdateURL() throws {
        let app = try makeAppBundle(
            name: "Chromium",
            extraInfoPlist: ["KSUpdateURL": "https://tools.google.com/service/update2"]
        )
        XCTAssertEqual(SelfUpdaterDetector().selfUpdater(for: app), .keystone)
    }

    /// An empty `KSUpdateURL` is not a usable channel. Mirrors the existing
    /// empty-string guard in `DefaultSparkleUpdateChecker.feedURL(for:)` —
    /// a present-but-blank key must not read as "this app is fine".
    func test_selfUpdater_ignoresEmptyKSUpdateURL() throws {
        let app = try makeAppBundle(name: "Blank", extraInfoPlist: ["KSUpdateURL": ""])
        XCTAssertNil(SelfUpdaterDetector().selfUpdater(for: app))
    }

    /// A non-string `KSUpdateURL` is malformed, not a channel.
    func test_selfUpdater_ignoresNonStringKSUpdateURL() throws {
        let app = try makeAppBundle(name: "Wrong", extraInfoPlist: ["KSUpdateURL": 42])
        XCTAssertNil(SelfUpdaterDetector().selfUpdater(for: app))
    }

    // MARK: - Squirrel

    /// Electron apps ship Squirrel.Mac as an embedded framework rather than
    /// advertising a feed in `Info.plist`, so the only signal is the
    /// framework's presence on disk.
    func test_selfUpdater_detectsSquirrelFromEmbeddedFramework() throws {
        let app = try makeAppBundle(name: "Electra", extraInfoPlist: [:], embedsSquirrel: true)
        XCTAssertEqual(SelfUpdaterDetector().selfUpdater(for: app), .squirrel)
    }

    /// A `Frameworks` directory without Squirrel is not a signal — most
    /// apps have one.
    func test_selfUpdater_ignoresFrameworksDirectoryWithoutSquirrel() throws {
        let app = try makeAppBundle(name: "Plain", extraInfoPlist: [:])
        let frameworks = app.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("Other.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        XCTAssertNil(SelfUpdaterDetector().selfUpdater(for: app))
    }

    // MARK: - Precedence

    /// When both signals are present the explicit feed URL wins: it names a
    /// concrete update service, which is the more specific claim.
    func test_selfUpdater_keystoneTakesPrecedenceOverSquirrel() throws {
        let app = try makeAppBundle(
            name: "Both",
            extraInfoPlist: ["KSUpdateURL": "https://tools.google.com/service/update2"],
            embedsSquirrel: true
        )
        XCTAssertEqual(SelfUpdaterDetector().selfUpdater(for: app), .keystone)
    }

    // MARK: - Absent and malformed

    /// An app with neither signal has no detectable updater — it lands in
    /// the "not monitored" bucket, which is the one worth acting on.
    func test_selfUpdater_isNilWhenNoSignalsPresent() throws {
        let app = try makeAppBundle(name: "Bare", extraInfoPlist: [:])
        XCTAssertNil(SelfUpdaterDetector().selfUpdater(for: app))
    }

    /// A bundle whose `Info.plist` is missing entirely must classify as
    /// "no updater", never trap. Discovery can race an app being removed.
    func test_selfUpdater_isNilWhenBundleIsMissing() {
        let app = AppInfo(
            name: "Ghost",
            bundleID: "com.acme.ghost",
            version: "1.0",
            bundleURL: tempDirectory.appendingPathComponent("Ghost.app", isDirectory: true),
            isAppStore: false
        )
        XCTAssertNil(SelfUpdaterDetector().selfUpdater(for: app))
    }

    /// An unreadable `Info.plist` (garbage bytes) degrades to nil rather
    /// than throwing out of a non-throwing call.
    func test_selfUpdater_isNilWhenInfoPlistIsCorrupt() throws {
        let appURL = tempDirectory.appendingPathComponent("Corrupt.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        let app = AppInfo(
            name: "Corrupt",
            bundleID: "com.acme.corrupt",
            version: "1.0",
            bundleURL: appURL,
            isAppStore: false
        )
        XCTAssertNil(SelfUpdaterDetector().selfUpdater(for: app))
    }

    // MARK: - Helpers

    /// Builds a minimal `.app` fixture. `Bundle(url:)` reads `Info.plist`
    /// from a directory this shape without needing a real executable, which
    /// is what `SparkleUpdateCheckerTests` already relies on.
    private func makeAppBundle(
        name: String,
        extraInfoPlist: [String: Any],
        embedsSquirrel: Bool = false
    ) throws -> AppInfo {
        let appURL = tempDirectory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.\(name.lowercased())",
            "CFBundleName": name,
            "CFBundleShortVersionString": "1.0"
        ]
        for (key, value) in extraInfoPlist {
            plist[key] = value
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if embedsSquirrel {
            try FileManager.default.createDirectory(
                at: contents
                    .appendingPathComponent("Frameworks", isDirectory: true)
                    .appendingPathComponent("Squirrel.framework", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return AppInfo(
            name: name,
            bundleID: "com.acme.\(name.lowercased())",
            version: "1.0",
            bundleURL: appURL,
            isAppStore: false
        )
    }
}
