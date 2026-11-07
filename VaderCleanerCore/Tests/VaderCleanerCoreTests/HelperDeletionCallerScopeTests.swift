// HelperDeletionCallerScopeTests.swift
// Pins the helper's per-account deletion rules to the connecting caller's own user id.

import Darwin
import Foundation
import Testing
@testable import VaderCleanerCore

/// The helper runs as root for every account on the Mac, so its code-signing
/// check alone would let one account's copy of the app delete another
/// account's files. Each rule here covers a location that belongs to one
/// account, and each must match that account to the caller.
@Suite("Helper deletion is scoped to the caller's own account")
struct HelperDeletionCallerScopeTests {

    /// A temp-directory stand-in for `/Users`, `/Volumes` and
    /// `/private/var/folders`. Everything created in it is owned by the user
    /// running the tests, which plays the caller.
    private struct Fixture {
        let root: URL
        let usersRoot: URL
        let volumesRoot: URL
        let temporaryRoot: URL
        let policy: HelperDeletionPolicy

        init() throws {
            root = try TestHelpers.createTempDirectory()
            usersRoot = root.appendingPathComponent("Users", isDirectory: true)
            volumesRoot = root.appendingPathComponent("Volumes", isDirectory: true)
            temporaryRoot = root.appendingPathComponent("private/var/folders", isDirectory: true)
            for directory in [usersRoot, volumesRoot, temporaryRoot] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            policy = HelperDeletionPolicy(
                allowedDescendantRoots: [],
                allowedUserLaunchAgentsRoot: usersRoot,
                allowedLanguageResourceRoots: [],
                volumesRoot: volumesRoot,
                perUserTemporaryRoot: temporaryRoot
            )
        }

        /// A home folder the caller owns, as `/Users/<name>` is.
        func ownedHome(_ name: String) throws -> URL {
            let home = usersRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }

        /// A per-user temporary folder the caller owns, as
        /// `/private/var/folders/<xx>/<id>` is.
        func ownedTemporaryFolder() throws -> URL {
            let folder = temporaryRoot.appendingPathComponent("zz/abc123", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        func tearDown() {
            TestHelpers.tearDownTempDirectory(root)
        }
    }

    private let caller = getuid()
    private var otherAccount: uid_t { caller + 1 }

    // MARK: - User LaunchAgents

    @Test("A LaunchAgent plist in the caller's own home is removable")
    func ownLaunchAgentIsAllowed() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let agent = try fixture.ownedHome("me")
            .appendingPathComponent("Library/LaunchAgents/com.example.agent.plist")

        #expect(try fixture.policy.validateDeletionPath(agent.path, callerUID: caller) == agent.standardizedFileURL)
    }

    @Test("Another account's LaunchAgent plist, or one asked for by an unknown caller, is refused")
    func otherAccountsLaunchAgentIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let agent = try fixture.ownedHome("me")
            .appendingPathComponent("Library/LaunchAgents/com.example.agent.plist")

        #expect(throws: HelperDeletionValidationError.disallowedPath(agent.path)) {
            _ = try fixture.policy.validateDeletionPath(agent.path, callerUID: otherAccount)
        }
        #expect(throws: HelperDeletionValidationError.disallowedPath(agent.path)) {
            _ = try fixture.policy.validateDeletionPath(agent.path)
        }
    }

    @Test("A LaunchAgent plist under a home folder that doesn't exist is refused")
    func missingHomeIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let agent = fixture.usersRoot
            .appendingPathComponent("nobody/Library/LaunchAgents/com.example.agent.plist")

        #expect(throws: HelperDeletionValidationError.disallowedPath(agent.path)) {
            _ = try fixture.policy.validateDeletionPath(agent.path, callerUID: caller)
        }
    }

    // MARK: - Per-volume Trash

    @Test("An item in the caller's own Trash on another volume is removable")
    func ownVolumeTrashIsAllowed() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let item = fixture.volumesRoot.appendingPathComponent("External/.Trashes/\(caller)/file.bin")

        #expect(try fixture.policy.validateDeletionPath(item.path, callerUID: caller) == item.standardizedFileURL)
    }

    @Test("Another account's Trash on another volume, or an unknown caller, is refused")
    func otherAccountsVolumeTrashIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let item = fixture.volumesRoot.appendingPathComponent("External/.Trashes/\(otherAccount)/file.bin")

        #expect(throws: HelperDeletionValidationError.disallowedPath(item.path)) {
            _ = try fixture.policy.validateDeletionPath(item.path, callerUID: caller)
        }
        #expect(throws: HelperDeletionValidationError.disallowedPath(item.path)) {
            _ = try fixture.policy.validateDeletionPath(item.path)
        }
    }

    // MARK: - Per-user temporary folders

    @Test("An item inside the caller's own temporary folder is removable")
    func ownTemporaryItemIsAllowed() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let item = try fixture.ownedTemporaryFolder().appendingPathComponent("C/com.example/cache.db")

        #expect(try fixture.policy.validateDeletionPath(item.path, callerUID: caller) == item.standardizedFileURL)
    }

    @Test("Another account's temporary folder, or an unknown caller, is refused")
    func otherAccountsTemporaryItemIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let item = try fixture.ownedTemporaryFolder().appendingPathComponent("C/com.example/cache.db")

        #expect(throws: HelperDeletionValidationError.disallowedPath(item.path)) {
            _ = try fixture.policy.validateDeletionPath(item.path, callerUID: otherAccount)
        }
        #expect(throws: HelperDeletionValidationError.disallowedPath(item.path)) {
            _ = try fixture.policy.validateDeletionPath(item.path)
        }
    }

    @Test("The caller's temporary folder itself, and the levels above it, stay")
    func temporaryFolderItselfIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let folder = try fixture.ownedTemporaryFolder()

        for path in [folder.path, folder.deletingLastPathComponent().path] {
            #expect(throws: HelperDeletionValidationError.disallowedPath(path), "\(path)") {
                _ = try fixture.policy.validateDeletionPath(path, callerUID: caller)
            }
        }
    }

    @Test("The production policy scopes the real temporary folder to its owner, in either spelling")
    func productionTemporaryFolderIsScoped() throws {
        // `temporaryDirectory` is `/var/folders/<xx>/<id>/T/`; the helper also
        // receives it as `/private/var/...`. The item exists, as anything the
        // app asks the helper to remove does: Foundation folds the two
        // spellings together only for a path that is on disk.
        let directory = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(directory) }
        let item = directory.appendingPathComponent("file.bin")
        try Data().write(to: item)
        try #require(item.path.hasPrefix("/var/folders/") || item.path.hasPrefix("/private/var/folders/"))
        let privatePath = item.path.hasPrefix("/private") ? item.path : "/private" + item.path
        let aliasPath = String(privatePath.dropFirst("/private".count))

        for path in [privatePath, aliasPath] {
            #expect(throws: Never.self, "\(path)") {
                _ = try HelperDeletionPolicy.production.validateDeletionPath(path, callerUID: caller)
            }
            #expect(throws: HelperDeletionValidationError.self, "\(path)") {
                _ = try HelperDeletionPolicy.production.validateDeletionPath(path, callerUID: otherAccount)
            }
        }
    }
}
