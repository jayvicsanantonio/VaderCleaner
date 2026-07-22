// ExclusionEntryTests.swift
// Tests how an ignored path is presented in the list: readable name, abbreviated location, and whether it still exists on disk.

import XCTest
@testable import VaderCleaner

final class ExclusionEntryTests: XCTestCase {

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
    func test_nameIsTheLastPathComponent() {
        let entry = entries(["\(home)/Developer"]).first

        XCTAssertEqual(entry?.name, "Developer")
    }

    /// Home is abbreviated the way Finder and the shell show it, so the
    /// location stays readable at a glance.
    func test_locationAbbreviatesHome() {
        let entry = entries(["\(home)/Developer/Projects"]).first

        XCTAssertEqual(entry?.location, "~/Developer")
    }

    func test_locationOutsideHomeIsLeftAbsolute() {
        let entry = entries(["/Volumes/Backup/Archive"]).first

        XCTAssertEqual(entry?.location, "/Volumes/Backup")
    }

    /// A path directly in home has no meaningful parent to show beyond "~".
    func test_locationForAnItemDirectlyInHome() {
        let entry = entries(["\(home)/Downloads"]).first

        XCTAssertEqual(entry?.location, "~")
    }

    /// A prefix match isn't enough — `/Users/someoneelse` is not inside
    /// `/Users/someone`, and abbreviating it to `~` would be a lie.
    func test_locationDoesNotAbbreviateASimilarlyNamedHome() {
        let entry = entries(["/Users/someoneelse/Developer"]).first

        XCTAssertEqual(entry?.location, "/Users/someoneelse")
    }

    // MARK: - Existence

    /// A folder the user deleted or renamed leaves an entry that will never
    /// match anything again. It has to look different, or the list silently
    /// accumulates dead weight.
    func test_marksMissingPaths() {
        let live = "\(home)/Developer"
        let dead = "\(home)/Gone"

        let result = entries([live, dead], existing: [live])

        XCTAssertEqual(result.first { $0.path == live }?.exists, true)
        XCTAssertEqual(result.first { $0.path == dead }?.exists, false)
    }

    // MARK: - Ordering

    /// Insertion order is the store's contract — the UI shows newly added
    /// entries at the end, so the presentation layer must not re-sort.
    func test_preservesInputOrder() {
        let paths = ["\(home)/B", "\(home)/A", "\(home)/C"]

        XCTAssertEqual(entries(paths).map(\.path), paths)
    }

    func test_emptyInputProducesNoEntries() {
        XCTAssertTrue(entries([]).isEmpty)
    }

    /// The row identity is the path, so SwiftUI keeps selection stable when
    /// the list is rebuilt after an existence refresh.
    func test_identityIsThePath() {
        let entry = entries(["\(home)/Developer"]).first

        XCTAssertEqual(entry?.id, "\(home)/Developer")
    }
}
