// LaunchAgentRemovalTests.swift
// Pins how LaunchAgentManager stops and trashes a user agent, verifies enable/disable against launchd's own answer, and discovers symlinked and BundleProgram plists.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
final class LaunchAgentRemovalTests {

    private let directory: URL

    init() throws {
        directory = try TestHelpers.createTempDirectory()
    }

    deinit {
        TestHelpers.tearDownTempDirectory(directory)
    }

    // MARK: - Remove

    @Test
    func remove_stopsTheRunningJobThenMovesThePlistToTheTrash() async throws {
        let plist = try writePlist(label: "com.example.doomed")
        let launchctlCalls = TestBox<[[String]]>([])
        let recycled = TestBox<[URL]>([])
        let manager = makeManager(
            launchctl: { launchctlCalls.value.append($0) },
            recycle: { urls in
                recycled.value += urls
                return Set(urls)
            }
        )
        let agent = try #require(manager.userAgents().first)

        try await manager.remove(agent)

        #expect(launchctlCalls.value == [["bootout", "gui/\(getuid())/com.example.doomed"]])
        #expect(recycled.value.map(\.lastPathComponent) == [plist.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: plist.path), "only the recycler may move it")
    }

    @Test(arguments: [3, 113])
    func remove_treatsAJobThatIsNotLoadedAsAlreadyStopped(exitStatus: Int) async throws {
        try writePlist(label: "com.example.unloaded")
        let recycled = TestBox(0)
        let manager = makeManager(
            launchctl: { _ in
                throw NSError(domain: LaunchAgentManager.launchctlErrorDomain, code: exitStatus)
            },
            recycle: { urls in
                recycled.value += urls.count
                return Set(urls)
            }
        )
        let agent = try #require(manager.userAgents().first)

        try await manager.remove(agent)

        #expect(recycled.value == 1)
    }

    @Test
    func remove_keepsThePlistWhenTheJobCannotBeStopped() async throws {
        try writePlist(label: "com.example.stuck")
        let recycled = TestBox(0)
        let manager = makeManager(
            launchctl: { _ in
                throw NSError(domain: LaunchAgentManager.launchctlErrorDomain, code: 5)
            },
            recycle: { urls in
                recycled.value += urls.count
                return Set(urls)
            }
        )
        let agent = try #require(manager.userAgents().first)

        await #expect(throws: (any Error).self) { try await manager.remove(agent) }

        #expect(recycled.value == 0, "a job that is still running must keep its plist")
    }

    @Test
    func remove_throwsWhenThePlistDoesNotReachTheTrash() async throws {
        try writePlist(label: "com.example.locked")
        let manager = makeManager(recycle: { _ in [] })
        let agent = try #require(manager.userAgents().first)

        await #expect(throws: LaunchAgentError.self) { try await manager.remove(agent) }
    }

    /// launchctl stops a job by label, and two plists can share one. Which of
    /// them launchd loaded isn't known, so stopping could take down the job of
    /// the plist the user is keeping.
    @Test
    func remove_leavesTheJobRunningWhenAnotherPlistSharesItsLabel() async throws {
        let plist = try writePlist(label: "com.example.shared")
        let other = directory.appendingPathComponent("com.example.shared.copy.plist")
        try plistData(["Label": "com.example.shared", "Program": "/bin/true"]).write(to: other)
        let launchctlCalls = TestBox(0)
        let recycled = TestBox<[URL]>([])
        let manager = makeManager(
            launchctl: { _ in launchctlCalls.value += 1 },
            recycle: { urls in
                recycled.value += urls
                return Set(urls)
            }
        )
        let agent = try #require(manager.userAgents().first { $0.path.lastPathComponent == plist.lastPathComponent })

        try await manager.remove(agent)

        #expect(launchctlCalls.value == 0)
        #expect(recycled.value.map(\.lastPathComponent) == [plist.lastPathComponent])
    }

    @Test
    func remove_succeedsWhenThePlistIsAlreadyGone() async throws {
        let plist = try writePlist(label: "com.example.gone")
        let recycled = TestBox(0)
        let launchctlCalls = TestBox(0)
        let manager = makeManager(
            launchctl: { _ in launchctlCalls.value += 1 },
            recycle: { urls in
                recycled.value += urls.count
                return []
            }
        )
        let agent = try #require(manager.userAgents().first)
        try FileManager.default.removeItem(at: plist)

        try await manager.remove(agent)

        #expect(launchctlCalls.value == 1, "the job can outlive its plist")
        #expect(recycled.value == 0)
    }

    // MARK: - Enable / disable

    @Test
    func disable_throwsWhenLaunchdStillListsTheJob() throws {
        try writePlist(label: "com.example.sticky")
        let manager = makeManager(loaded: ["com.example.sticky"])
        let agent = try #require(manager.userAgents().first)

        // The legacy `unload` subcommand exits 0 even when it fails.
        #expect(throws: LaunchAgentError.self) { try manager.disable(agent) }
    }

    @Test
    func enable_throwsWhenLaunchdDoesNotListTheJob() throws {
        try writePlist(label: "com.example.broken")
        let manager = makeManager(loaded: [])
        let agent = try #require(manager.userAgents().first)

        // The legacy `load` subcommand exits 0 even when it fails.
        #expect(throws: LaunchAgentError.self) { try manager.enable(agent) }
    }

    // MARK: - Discovery

    @Test
    func userAgents_includesASymlinkToAPlistFile() throws {
        let elsewhere = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(elsewhere) }
        let target = elsewhere.appendingPathComponent("com.example.dotfile.plist")
        try plistData(["Label": "com.example.dotfile", "Program": "/bin/true"]).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("com.example.dotfile.plist"),
            withDestinationURL: target
        )

        #expect(makeManager().userAgents().map(\.label) == ["com.example.dotfile"])
    }

    @Test
    func userAgents_skipsADanglingSymlink() throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("com.example.dangling.plist"),
            withDestinationURL: directory.appendingPathComponent("missing.plist")
        )

        #expect(makeManager().userAgents().isEmpty)
    }

    @Test
    func userAgents_skipsASymlinkToADirectory() throws {
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("com.example.folder.plist"),
            withDestinationURL: folder
        )

        #expect(makeManager().userAgents().isEmpty)
    }

    @Test
    func programPath_fallsBackToBundleProgram() {
        let plist: [String: Any] = ["BundleProgram": "Contents/MacOS/agent"]

        #expect(LaunchAgentManager.programPath(from: plist) == "Contents/MacOS/agent")
    }

    // MARK: - Icon source

    @Test(arguments: [
        ("/Applications/Acme.app/Contents/Helpers/updater", "/Applications/Acme.app"),
        ("/Applications/Acme.app", "/Applications/Acme.app"),
        ("/Applications/Tools/Acme.APP/Contents/MacOS/acme", "/Applications/Tools/Acme.APP")
    ])
    func appBundlePath_findsTheEnclosingBundle(program: String, expected: String) {
        #expect(agent(program: program).appBundlePath == expected)
    }

    @Test(arguments: [
        "/Users/me/Library/com.apple.helper/run",
        "/opt/tool.appdata/run",
        "/usr/local/bin/agent"
    ])
    func appBundlePath_ignoresPathsThatOnlyContainDotApp(program: String) {
        #expect(agent(program: program).appBundlePath == nil)
    }

    // MARK: - Helpers

    private func agent(program: String) -> LaunchAgent {
        LaunchAgent(
            label: "com.example.agent",
            path: URL(fileURLWithPath: "/tmp/com.example.agent.plist"),
            programPath: program,
            isEnabled: true,
            domain: .user
        )
    }

    private func makeManager(
        loaded: Set<String> = [],
        launchctl: @escaping LaunchAgentManager.LaunchctlRunner = { _ in },
        recycle: @escaping LaunchAgentManager.Recycle = { Set($0) }
    ) -> LaunchAgentManager {
        LaunchAgentManager(
            userAgentsDirectory: directory,
            systemAgentDirectories: [],
            loadedLabels: { loaded },
            launchctl: launchctl,
            helperProvider: { _ in nil },
            recycle: recycle
        )
    }

    @discardableResult
    private func writePlist(label: String) throws -> URL {
        let url = directory.appendingPathComponent("\(label).plist")
        try plistData(["Label": label, "Program": "/bin/true"]).write(to: url)
        return url
    }

    private func plistData(_ contents: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
    }
}
