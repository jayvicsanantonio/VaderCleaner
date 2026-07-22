// ScanSelectionSeedTests.swift
// Pins ScanSelectionSeed's builders: safe-by-default seeding and exact-category selection, including the running tallies the Cleanup Manager reads in O(1).

import XCTest
@testable import VaderCleaner

final class ScanSelectionSeedTests: XCTestCase {

    /// The safe-defaults seed must select every file in a regenerable /
    /// already-discarded category and leave user-data categories out — the
    /// same rule `scan()` and Smart Scan apply, so all seeded surfaces agree.
    func test_safeDefaults_selectsOnlySafeCategories() async {
        let cache = file("a", 100, .userCache)
        let log = file("b", 200, .systemLogs)
        let trash = file("c", 300, .trash)
        let mail = file("d", 400, .mailAttachments)
        let backup = file("e", 500, .iosBackups)
        let result = ScanResult(items: [cache, log, trash, mail, backup])

        let seed = await ScanSelectionSeed.safeDefaults(from: result)

        XCTAssertEqual(seed.urls, [cache.url, log.url, trash.url])
        XCTAssertEqual(seed.totalBytes, 600)
        XCTAssertEqual(seed.bytesByCategory, [.userCache: 100, .systemLogs: 200, .trash: 300])
        XCTAssertEqual(seed.countByCategory, [.userCache: 1, .systemLogs: 1, .trash: 1])
    }

    /// The category-scoped seed must cover exactly the requested categories —
    /// no bleed from siblings — so a dashboard card's Review opens with the
    /// selected total equal to the card's displayed size.
    func test_selection_coversExactlyTheRequestedCategories() async {
        let cacheA = file("a", 100, .userCache)
        let cacheB = file("b", 30, .userCache)
        let sysCache = file("c", 200, .systemCache)
        let trash = file("t", 400, .trash)
        let result = ScanResult(items: [cacheA, cacheB, sysCache, trash])

        let seed = await ScanSelectionSeed.selection(of: [.userCache, .systemCache], from: result)

        XCTAssertEqual(seed.urls, [cacheA.url, cacheB.url, sysCache.url])
        XCTAssertEqual(seed.totalBytes, 330)
        XCTAssertEqual(seed.bytesByCategory, [.userCache: 130, .systemCache: 200])
        XCTAssertEqual(seed.countByCategory, [.userCache: 2, .systemCache: 1])
    }

    /// Requesting a category the result doesn't contain must yield an empty
    /// seed rather than trap or invent entries.
    func test_selection_ofAbsentCategory_isEmpty() async {
        let result = ScanResult(items: [file("a", 100, .userCache)])

        let seed = await ScanSelectionSeed.selection(of: [.trash], from: result)

        XCTAssertEqual(seed, ScanSelectionSeed())
    }

    /// Web Development Junk is only half regenerable-at-no-cost: the package
    /// caches re-download on demand, but a project's `node_modules` costs that
    /// project a full reinstall the next time it's touched. The caches are
    /// pre-checked; the project artifacts stay an explicit choice, and the
    /// tallies count only what's actually selected.
    func test_safeDefaults_leavesProjectArtifactsUnchecked() async {
        let cache = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/.npm/_cacache/a"),
            size: 100, lastAccessDate: nil, lastModifiedDate: nil, category: .webDevJunk
        )
        let project = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Developer/pixel-prompt/node_modules"),
            size: 900, lastAccessDate: nil, lastModifiedDate: nil, category: .webDevJunk
        )
        let userCache = file("c", 50, .userCache)
        let result = ScanResult(items: [cache, project, userCache])

        let seed = await ScanSelectionSeed.safeDefaults(from: result, cacheRoots: ["/Users/me/.npm"])

        XCTAssertEqual(seed.urls, [cache.url, userCache.url])
        XCTAssertEqual(seed.totalBytes, 150)
        XCTAssertEqual(seed.bytesByCategory, [.webDevJunk: 100, .userCache: 50])
        XCTAssertEqual(seed.countByCategory, [.webDevJunk: 1, .userCache: 1])
    }

    /// A card's Review seeds the same way: opening Web Development Junk must
    /// not arrive with every project's dependencies already checked.
    func test_selection_ofWebDevJunk_leavesProjectArtifactsUnchecked() async {
        let cache = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/.npm/_cacache/a"),
            size: 100, lastAccessDate: nil, lastModifiedDate: nil, category: .webDevJunk
        )
        let project = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Developer/pixel-prompt/node_modules"),
            size: 900, lastAccessDate: nil, lastModifiedDate: nil, category: .webDevJunk
        )
        let result = ScanResult(items: [cache, project])

        let seed = await ScanSelectionSeed.selection(
            of: [.webDevJunk],
            from: result,
            cacheRoots: ["/Users/me/.npm"]
        )

        XCTAssertEqual(seed.urls, [cache.url])
        XCTAssertEqual(seed.totalBytes, 100)
    }

    // MARK: - Helpers

    private func file(_ name: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/seed-tests/\(category.rawValue)/\(name)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }
}
