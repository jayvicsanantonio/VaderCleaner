// LaunchAgentManagerTests.swift
// Exercises LaunchAgentManager plist parsing, launchctl-loaded status, and disable/remove routing through temp fixtures and injected fakes.

import XCTest
@testable import VaderCleaner

final class LaunchAgentManagerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempDir)
    }

    // MARK: - launchctl list parsing

    func test_parseLoadedLabels_extractsLabelColumnSkippingHeader() {
        let output = """
        PID\tStatus\tLabel
        1234\t0\tcom.apple.Finder
        -\t0\tcom.example.updater
        \t
        """
        let labels = LaunchAgentManager.parseLoadedLabels(from: output)
        XCTAssertEqual(labels, ["com.apple.Finder", "com.example.updater"])
    }

    // MARK: - programPath extraction

    func test_programPath_prefersProgramKey() {
        let plist: [String: Any] = ["Program": "/usr/local/bin/agent"]
        XCTAssertEqual(LaunchAgentManager.programPath(from: plist), "/usr/local/bin/agent")
    }

    func test_programPath_fallsBackToFirstProgramArgument() {
        let plist: [String: Any] = ["ProgramArguments": ["/opt/tool/run", "--flag"]]
        XCTAssertEqual(LaunchAgentManager.programPath(from: plist), "/opt/tool/run")
    }

    func test_programPath_nilWhenAbsent() {
        XCTAssertNil(LaunchAgentManager.programPath(from: [:]))
    }

    // MARK: - userAgents discovery

    func test_userAgents_parsesLabelProgramAndLoadedStatus() throws {
        try writePlist(
            named: "com.example.loaded.plist",
            label: "com.example.loaded",
            program: "/opt/example/loaded"
        )
        try writePlist(
            named: "com.example.unloaded.plist",
            label: "com.example.unloaded",
            programArguments: ["/opt/example/unloaded", "-x"]
        )

        let manager = makeManager(loaded: ["com.example.loaded"])
        let agents = manager.userAgents().sorted { $0.label < $1.label }

        XCTAssertEqual(agents.map(\.label),
                       ["com.example.loaded", "com.example.unloaded"])
        XCTAssertEqual(agents[0].programPath, "/opt/example/loaded")
        XCTAssertTrue(agents[0].isEnabled)
        XCTAssertEqual(agents[1].programPath, "/opt/example/unloaded")
        XCTAssertFalse(agents[1].isEnabled)
        XCTAssertEqual(agents[0].domain, .user)
    }

    func test_userAgents_fallsBackToFilenameWhenLabelMissing() throws {
        let url = tempDir.appendingPathComponent("no-label.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Program": "/bin/true"],
            format: .xml,
            options: 0
        )
        try data.write(to: url)

        let manager = makeManager(loaded: [])
        XCTAssertEqual(manager.userAgents().first?.label, "no-label")
    }

    func test_userAgents_ignoresNonPlistFiles() throws {
        try "junk".write(
            to: tempDir.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8
        )
        let manager = makeManager(loaded: [])
        XCTAssertTrue(manager.userAgents().isEmpty)
    }

    // MARK: - enable / disable

    func test_disable_invokesLaunchctlUnloadWithAgentPath() throws {
        try writePlist(named: "a.plist", label: "a", program: "/bin/a")
        var captured: [String]?
        let manager = makeManager(loaded: ["a"], launchctl: { captured = $0 })
        let agent = try XCTUnwrap(manager.userAgents().first)

        try manager.disable(agent)

        // `-w` records the agent as disabled in launchd's per-user override
        // database so it stays off across logins, not just for the session.
        XCTAssertEqual(captured, ["unload", "-w", agent.path.path])
    }

    func test_enable_invokesLaunchctlLoadWithAgentPath() throws {
        try writePlist(named: "a.plist", label: "a", program: "/bin/a")
        var captured: [String]?
        let manager = makeManager(loaded: [], launchctl: { captured = $0 })
        let agent = try XCTUnwrap(manager.userAgents().first)

        try manager.enable(agent)

        // `-w` clears the agent's launchd override entry so `load` reliably
        // re-registers it even when it was previously disabled.
        XCTAssertEqual(captured, ["load", "-w", agent.path.path])
    }

    // MARK: - remove

    func test_remove_userAgentDeletesFileInProcess() async throws {
        try writePlist(named: "doomed.plist", label: "doomed", program: "/bin/x")
        let manager = makeManager(loaded: [])
        let agent = try XCTUnwrap(manager.userAgents().first)

        try await manager.remove(agent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.path.path))
    }

    func test_remove_systemAgentRoutesThroughPrivilegedHelper() async throws {
        let systemDir = tempDir.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: systemDir, withIntermediateDirectories: true)
        let plistURL = systemDir.appendingPathComponent("com.sys.daemon.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.sys.daemon", "Program": "/usr/sbin/sysd"],
            format: .xml, options: 0
        )
        try data.write(to: plistURL)

        let fake = FakeRemovalHelper()
        let manager = LaunchAgentManager(
            userAgentsDirectory: tempDir,
            systemAgentDirectories: [systemDir],
            loadedLabels: { [] },
            launchctl: { _ in },
            helperProvider: { _ in fake }
        )
        let agent = try XCTUnwrap(manager.systemAgents().first)

        try await manager.remove(agent)

        // Directory enumeration resolves the /var → /private/var symlink on
        // the temp path, so match by suffix rather than the absolute string.
        let received = try XCTUnwrap(fake.removedLaunchAgentPath)
        XCTAssertTrue(
            received.hasSuffix("/system/com.sys.daemon.plist"),
            "Helper received unexpected path: \(received)"
        )
        // System file routed through the helper; not deleted in-process.
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
    }

    // MARK: - Helpers

    private func makeManager(
        loaded: Set<String>,
        launchctl: @escaping (_ args: [String]) throws -> Void = { _ in }
    ) -> LaunchAgentManager {
        LaunchAgentManager(
            userAgentsDirectory: tempDir,
            systemAgentDirectories: [],
            loadedLabels: { loaded },
            launchctl: launchctl,
            helperProvider: { _ in nil }
        )
    }

    private func writePlist(
        named name: String,
        label: String,
        program: String? = nil,
        programArguments: [String]? = nil
    ) throws {
        var dict: [String: Any] = ["Label": label]
        if let program { dict["Program"] = program }
        if let programArguments { dict["ProgramArguments"] = programArguments }
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
        try data.write(to: tempDir.appendingPathComponent(name))
    }
}

/// Captures the path passed to `removeLaunchAgent` and replies success.
private final class FakeRemovalHelper: NSObject, VaderCleanerHelperProtocol {
    private(set) var removedLaunchAgentPath: String?

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) { reply(nil) }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {
        removedLaunchAgentPath = path
        reply(nil)
    }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushDNSCache(reply: @escaping (Error?) -> Void) { reply(nil) }
    func reindexSpotlight(reply: @escaping (Error?) -> Void) { reply(nil) }
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) { reply(nil) }
}
