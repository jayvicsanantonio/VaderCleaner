// ExtensionDiscoveryTests.swift
// Exercises the five Extensions Manager discovery types against hermetic temp-directory fixtures so no real Safari/Mail/launch-agent state is touched.

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

    // MARK: - Launch agents

    /// `userAgents()` reads every plist under `~/Library/LaunchAgents` and
    /// derives `name` from the `Label` key.
    func test_launchAgents_userAgentsReadsLabelAndPath() async throws {
        let agentsDir = tempHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: agentsDir, withIntermediateDirectories: true
        )
        try writePlist(
            ["Label": "com.acme.updater",
             "ProgramArguments": ["/usr/local/bin/acme"]],
            to: agentsDir.appendingPathComponent("com.acme.updater.plist")
        )

        let discovery = LaunchAgentDiscovery(homeDirectory: tempHome, systemRoots: [])
        let agents = await discovery.userAgents()

        XCTAssertEqual(agents.count, 1)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertEqual(agent.name, "com.acme.updater")
        XCTAssertEqual(agent.type, .loginItemFromApp)
        XCTAssertTrue(agent.isEnabled)
        XCTAssertEqual(
            agent.path.lastPathComponent, "com.acme.updater.plist"
        )
    }

    /// `Disabled = true` in the plist flips `isEnabled` to `false` — that
    /// key is the authoritative launchd source.
    func test_launchAgents_disabledKeyFlipsIsEnabled() async throws {
        let agentsDir = tempHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: agentsDir, withIntermediateDirectories: true
        )
        try writePlist(
            ["Label": "com.acme.enabled"],
            to: agentsDir.appendingPathComponent("com.acme.enabled.plist")
        )
        try writePlist(
            ["Label": "com.acme.disabled", "Disabled": true],
            to: agentsDir.appendingPathComponent("com.acme.disabled.plist")
        )

        let discovery = LaunchAgentDiscovery(homeDirectory: tempHome, systemRoots: [])
        let byName = Dictionary(
            uniqueKeysWithValues: await discovery.userAgents().map { ($0.name, $0) }
        )

        XCTAssertEqual(byName["com.acme.enabled"]?.isEnabled, true)
        XCTAssertEqual(byName["com.acme.disabled"]?.isEnabled, false)
    }

    /// `extensions()` is the protocol surface; for launch agents it must
    /// return the same set as `userAgents()`.
    func test_launchAgents_extensionsMirrorsUserAgents() async throws {
        let agentsDir = tempHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: agentsDir, withIntermediateDirectories: true
        )
        try writePlist(
            ["Label": "com.acme.one"],
            to: agentsDir.appendingPathComponent("com.acme.one.plist")
        )

        let discovery = LaunchAgentDiscovery(homeDirectory: tempHome, systemRoots: [])
        let viaProtocol = await discovery.extensions()
        let viaUserAgents = await discovery.userAgents()
        XCTAssertEqual(viaProtocol, viaUserAgents)
    }

    /// System-wide launch agents and daemons under `/Library/LaunchAgents`
    /// and `/Library/LaunchDaemons` are surfaced alongside the user's, so
    /// the "Login Items & Launch Agents" section doesn't miss common
    /// third-party background items.
    func test_launchAgents_surfacesSystemAgentsAndDaemons() async throws {
        let userDir = tempHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let sysAgents = tempSystem.appendingPathComponent("LaunchAgents", isDirectory: true)
        let sysDaemons = tempSystem.appendingPathComponent("LaunchDaemons", isDirectory: true)
        for dir in [userDir, sysAgents, sysDaemons] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try writePlist(
            ["Label": "com.user.agent"],
            to: userDir.appendingPathComponent("com.user.agent.plist")
        )
        try writePlist(
            ["Label": "com.system.agent"],
            to: sysAgents.appendingPathComponent("com.system.agent.plist")
        )
        try writePlist(
            ["Label": "com.system.daemon", "Disabled": true],
            to: sysDaemons.appendingPathComponent("com.system.daemon.plist")
        )

        let discovery = LaunchAgentDiscovery(
            homeDirectory: tempHome,
            systemRoots: [sysAgents, sysDaemons]
        )
        let byName = Dictionary(
            uniqueKeysWithValues: await discovery.userAgents().map { ($0.name, $0) }
        )

        XCTAssertEqual(
            Set(byName.keys),
            ["com.user.agent", "com.system.agent", "com.system.daemon"]
        )
        XCTAssertEqual(byName["com.system.agent"]?.type, .loginItemFromApp)
        XCTAssertEqual(byName["com.system.daemon"]?.isEnabled, false)
        XCTAssertEqual(
            byName["com.system.agent"]?.path.lastPathComponent,
            "com.system.agent.plist"
        )
        XCTAssertEqual(
            byName["com.system.agent"]?.path.deletingLastPathComponent().lastPathComponent,
            "LaunchAgents"
        )
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

    private func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
        try data.write(to: url)
    }

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
