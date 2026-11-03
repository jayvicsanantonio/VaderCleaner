// TestDefaults.swift
// Names for the throwaway UserDefaults suites tests create, placed in the temporary directory so a test run leaves nothing in the developer's ~/Library/Preferences.

import Foundation

extension UserDefaults {

    /// A fresh suite name for one test, `<label>.<UUID>`, as a path inside
    /// the temporary directory.
    ///
    /// A plain suite name puts the suite's plist in `~/Library/Preferences`,
    /// and nothing a test does can keep it from staying there: after
    /// `removePersistentDomain(forName:)`, `cfprefsd` writes the emptied
    /// domain back as an empty plist, even over a file the test deleted. Runs
    /// piled up tens of thousands of them, which the app-leftover scan then
    /// read as uninstalled apps. CFPreferences takes an absolute path as a
    /// domain, so a suite named this way keeps its plist — and that write-back
    /// — in the temporary directory instead.
    static func testSuiteName(_ label: String) -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaderCleanerTestDefaults", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(label).\(UUID().uuidString)").path
    }
}
