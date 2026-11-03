// TestDefaultsTests.swift
// Pins where every test's throwaway UserDefaults suite lives: in the temporary directory, never the developer's ~/Library/Preferences, and fresh for each call.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct TestDefaultsTests {

    @Test
    func aTestSuiteLivesOutsideTheUsersPreferences() throws {
        let suiteName = UserDefaults.testSuiteName("VaderCleanerTests.TestDefaults")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(42, forKey: "answer")
        defaults.synchronize()

        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\((suiteName as NSString).lastPathComponent).plist")
        #expect(FileManager.default.fileExists(atPath: suiteName + ".plist"))
        #expect(!FileManager.default.fileExists(atPath: preferences.path))
        #expect(UserDefaults(suiteName: suiteName)?.integer(forKey: "answer") == 42)
    }

    @Test
    func eachTestSuiteIsFresh() {
        #expect(UserDefaults.testSuiteName("VaderCleanerTests.TestDefaults")
            != UserDefaults.testSuiteName("VaderCleanerTests.TestDefaults"))
    }
}
