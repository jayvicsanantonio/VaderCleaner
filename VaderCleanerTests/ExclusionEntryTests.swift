// ExclusionEntryTests.swift
// Tests how an ignored path is presented in the list: readable name, abbreviated location, and whether it still exists on disk.

import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

@Suite
struct ExclusionEntryTests {

    private let home = "/Users/someone"

    private func entries(
        _ paths: [String],
        existing: Set<String> = []
    ) -> [ExclusionEntry] {
        ExclusionEntry.entries(
            for: paths,
            homeDirectory: home,
            exists: { existing.contains($0) }
        )
    }

    // MARK: - Naming

    /// The folder's own name is what the user recognises; the full path is
    /// supporting detail, not the headline.
    @Test
    func nameIsTheLastPathComponent() {
        let entry = entries(["\(home)/Developer"]).first

        #expect(entry?.name == "Developer")
    }

    /// Home is abbreviated the way Finder and the shell show it, so the
    /// location stays readable at a glance.
    @Test
    func locationAbbreviatesHome() {
        let entry = entries(["\(home)/Developer/Projects"]).first

        #expect(entry?.location == "~/Developer")
    }

    @Test
    func locationOutsideHomeIsLeftAbsolute() {
        let entry = entries(["/Volumes/Backup/Archive"]).first

        #expect(entry?.location == "/Volumes/Backup")
    }

    /// A path directly in home has no meaningful parent to show beyond "~".
    @Test
    func locationForAnItemDirectlyInHome() {
        let entry = entries(["\(home)/Downloads"]).first

        #expect(entry?.location == "~")
    }

    /// A prefix match isn't enough — `/Users/someoneelse` is not inside
    /// `/Users/someone`, and abbreviating it to `~` would be a lie.
    @Test
    func locationDoesNotAbbreviateASimilarlyNamedHome() {
        let entry = entries(["/Users/someoneelse/Developer"]).first

        #expect(entry?.location == "/Users/someoneelse")
    }

    // MARK: - Existence

    /// A folder the user deleted or renamed leaves an entry that will never
    /// match anything again. It has to look different, or the list silently
    /// accumulates dead weight.
    @Test
    func marksMissingPaths() {
        let live = "\(home)/Developer"
        let dead = "\(home)/Gone"

        let result = entries([live, dead], existing: [live])

        #expect(result.first { $0.path == live }?.exists == true)
        #expect(result.first { $0.path == dead }?.exists == false)
    }

    // MARK: - Ordering

    /// Insertion order is the store's contract — the UI shows newly added
    /// entries at the end, so the presentation layer must not re-sort.
    @Test
    func preservesInputOrder() {
        let paths = ["\(home)/B", "\(home)/A", "\(home)/C"]

        #expect(entries(paths).map(\.path) == paths)
    }

    @Test
    func emptyInputProducesNoEntries() {
        #expect(entries([]).isEmpty)
    }

    /// The row identity is the path, so SwiftUI keeps selection stable when
    /// the list is rebuilt after an existence refresh.
    @Test
    func identityIsThePath() {
        let entry = entries(["\(home)/Developer"]).first

        #expect(entry?.id == "\(home)/Developer")
    }
}
