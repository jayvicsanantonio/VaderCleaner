// PrivacyPermissionCheckerTests.swift
// Tests that PrivacyPermissionChecker.hasFullDiskAccess(testPaths:) probes paths via real file reads, and that its default probes and Settings link match what the installed macOS actually ships.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
final class PrivacyPermissionCheckerTests {

    private let tempDir: URL

    init() throws {
        tempDir = try TestHelpers.createTempDirectory()
    }

    deinit {
        TestHelpers.tearDownTempDirectory(tempDir)
    }

    @Test func returnsTrue_forReadableFile() throws {
        let file = try TestHelpers.createDummyFile(named: "readable.bin", size: 16, in: tempDir)
        #expect(PrivacyPermissionChecker.hasFullDiskAccess(testPaths: [file]))
    }

    @Test func returnsFalse_forNonexistentPath() {
        let missing = tempDir.appendingPathComponent("does_not_exist.bin")
        #expect(!PrivacyPermissionChecker.hasFullDiskAccess(testPaths: [missing]))
    }

    @Test func returnsFalse_forDirectoryPath() {
        // Real file reads fail on directories — relying on this distinguishes a granted-access
        // directory listing (which fileExists would confirm) from an actual readable file.
        #expect(!PrivacyPermissionChecker.hasFullDiskAccess(testPaths: [tempDir]))
    }

    @Test func returnsFalse_whenThereIsNothingToProbe() {
        #expect(!PrivacyPermissionChecker.hasFullDiskAccess(testPaths: []))
    }

    @Test func returnsTrue_whenAnyProbeIsReadable() throws {
        // A probe that a macOS release has removed must not hide the proof a
        // later probe gives — one unreadable path is not evidence of denial.
        let missing = tempDir.appendingPathComponent("does_not_exist.bin")
        let readable = try TestHelpers.createDummyFile(named: "readable.bin", size: 16, in: tempDir)
        #expect(PrivacyPermissionChecker.hasFullDiskAccess(testPaths: [missing, readable]))
    }

    @Test func defaultPath_returnsBool() {
        // Asserting only that the default-path overload returns *some* Bool — the actual
        // result depends on the host machine's TCC state, which would break CI either way
        // if asserted directly.
        let result: Bool = PrivacyPermissionChecker.hasFullDiskAccess()
        _ = result
    }

    @Test func defaultProbes_includeOneThatExistsOnThisMac() {
        // Existence is visible without Full Disk Access; only reading is gated.
        // If every probe is gone, the checker reports "denied" forever no
        // matter what the user grants, so this is what catches a macOS release
        // moving them.
        let existing = PrivacyPermissionChecker.defaultTestPaths.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        #expect(!existing.isEmpty)
    }

    @Test func settingsURL_namesAnExtensionThatIsInstalled() throws {
        // System Settings silently ignores a link to an extension it doesn't
        // have, leaving the user wherever the window last was — so the only
        // honest check is against the extensions macOS actually ships.
        let link = PrivacyPermissionChecker.fullDiskAccessSettingsURL.absoluteString
        let target = try #require(link.split(separator: ":").last?.split(separator: "?").first)

        let extensions = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions"),
            includingPropertiesForKeys: nil
        )
        let installed = extensions.compactMap { Bundle(url: $0)?.bundleIdentifier }
        #expect(installed.contains(String(target)))
    }

    @Test func settingsURL_targetsTheFullDiskAccessAnchor() {
        #expect(PrivacyPermissionChecker.fullDiskAccessSettingsURL.query == "Privacy_AllFiles")
    }
}
