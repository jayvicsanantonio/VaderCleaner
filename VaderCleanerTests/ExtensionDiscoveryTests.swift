// ExtensionDiscoveryTests.swift
// Exercises the Extensions Manager discovery types against hermetic temp-directory fixtures so no real Safari/Mail/browser state is touched.

import XCTest
@testable import VaderCleaner

final class ExtensionDiscoveryTests: XCTestCase {

    private var tempHome: URL!
    private var tempSystem: URL!

    override func setUpWithError() throws {
        tempHome = try TestHelpers.createTempDirectory()
        tempSystem = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempHome)
        TestHelpers.tearDownTempDirectory(tempSystem)
    }

    // MARK: - Safari

    /// Contract from the plan: `extensions()` returns an array (possibly
    /// empty). A home with no `Safari/Extensions` directory — the common
    /// case on modern macOS where extensions ship as `.appex` via
    /// PluginKit — must yield `[]`, never a crash.
    func test_safari_returnsEmptyArrayWhenDirectoryAbsent() async {
        let discovery = SafariExtensionDiscovery(homeDirectory: tempHome)
        let result = await discovery.extensions()
        XCTAssertEqual(result, [])
    }

    /// A planted legacy `.safariextz` archive is surfaced as a
    /// `.safariExtension` item.
    func test_safari_surfacesLegacyArchive() async throws {
        let extensionsDir = tempHome
            .appendingPathComponent("Library/Safari/Extensions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionsDir, withIntermediateDirectories: true
        )
        try TestHelpers.createDummyFile(
            named: "AdBlock.safariextz", size: 2048, in: extensionsDir
        )

        let discovery = SafariExtensionDiscovery(homeDirectory: tempHome)
        let result = await discovery.extensions()

        XCTAssertEqual(result.count, 1)
        let item = try XCTUnwrap(result.first)
        XCTAssertEqual(item.name, "AdBlock")
        XCTAssertEqual(item.type, .safariExtension)
        XCTAssertEqual(item.size, 2048)
    }

    // MARK: - Mail plugins

    /// `.mailbundle` directories under both the user and system Bundles
    /// roots are surfaced as `.mailPlugin` items.
    func test_mailPlugins_surfacesUserAndSystemBundles() async throws {
        let userBundles = tempHome
            .appendingPathComponent("Library/Mail/Bundles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: userBundles, withIntermediateDirectories: true
        )
        try makeBundle(named: "GPGMail.mailbundle", in: userBundles)
        try makeBundle(named: "SystemMailPlugin.mailbundle", in: tempSystem)

        let discovery = MailPluginDiscovery(
            homeDirectory: tempHome,
            systemBundlesDirectory: tempSystem
        )
        let names = Set(await discovery.extensions().map(\.name))

        XCTAssertTrue(names.contains("GPGMail"))
        XCTAssertTrue(names.contains("SystemMailPlugin"))
        for item in await discovery.extensions() {
            XCTAssertEqual(item.type, .mailPlugin)
        }
    }

    // MARK: - Internet plug-ins

    /// `.plugin` bundles under the user/system Internet Plug-Ins roots are
    /// surfaced as `.internetPlugin` items.
    func test_internetPlugins_surfacesUserAndSystemPlugins() async throws {
        let userPlugins = tempHome
            .appendingPathComponent("Library/Internet Plug-Ins", isDirectory: true)
        try FileManager.default.createDirectory(
            at: userPlugins, withIntermediateDirectories: true
        )
        try makeBundle(named: "Flash Player.plugin", in: userPlugins)
        try makeBundle(named: "QuickTime.plugin", in: tempSystem)

        let discovery = InternetPluginDiscovery(
            homeDirectory: tempHome,
            systemPluginsDirectory: tempSystem
        )
        let names = Set(await discovery.extensions().map(\.name))

        XCTAssertTrue(names.contains("Flash Player"))
        XCTAssertTrue(names.contains("QuickTime"))
    }

    // MARK: - Browser extensions

    /// A planted unpacked Chrome extension (manifest.json under
    /// `Extensions/<id>/<version>/`) is surfaced with the manifest name.
    func test_browser_surfacesChromeExtension() async throws {
        let versionDir = tempHome.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default/Extensions/abcdef/1.2.0",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: versionDir, withIntermediateDirectories: true
        )
        let manifest = #"{"name":"Tab Manager","version":"1.2.0"}"#
        try manifest.write(
            to: versionDir.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )

        let discovery = BrowserExtensionDiscovery(homeDirectory: tempHome)
        let chrome = await discovery.extensions()
            .filter { $0.type == .chromeExtension }

        XCTAssertEqual(chrome.count, 1)
        XCTAssertEqual(chrome.first?.name, "Tab Manager")
    }

    /// No browser profile directories → empty, not a crash.
    func test_browser_returnsEmptyWhenNoProfiles() async {
        let discovery = BrowserExtensionDiscovery(homeDirectory: tempHome)
        let result = await discovery.extensions()
        XCTAssertEqual(result, [])
    }

    // MARK: - Fixture helpers

    /// Creates a minimal `.bundle`-style directory with a Contents/ child so
    /// the size walk has something to sum.
    private func makeBundle(named name: String, in directory: URL) throws {
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents, withIntermediateDirectories: true
        )
        try TestHelpers.createDummyFile(named: "Info.plist", size: 128, in: contents)
    }
}
