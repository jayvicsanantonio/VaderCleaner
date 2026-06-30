// CleanupGroupTests.swift
// Pins how CleanupGroup maps scan categories into the four dashboard cards, which group is the hero, which allow direct cleaning, and how tiles aggregate a ScanResult.

import XCTest
import AppKit
@testable import VaderCleaner

final class CleanupGroupTests: XCTestCase {

    // MARK: - Category mapping

    /// Every junk category except the Large & Old Files ones must roll up into
    /// exactly one Cleanup card — otherwise scanned bytes would silently vanish
    /// from the dashboard breakdown.
    func test_everyJunkCategory_mapsToExactlyOneGroup() {
        let cleanupCategories = ScanCategory.allCases.filter { $0 != .largeFile && $0 != .oldFile }
        for category in cleanupCategories {
            let owning = CleanupGroup.allCases.filter { $0.categories.contains(category) }
            XCTAssertEqual(
                owning.count, 1,
                "\(category) must belong to exactly one CleanupGroup, found \(owning.map(\.rawValue))"
            )
        }
    }

    /// Large & Old Files categories belong to a different section and must not
    /// map to any Cleanup card.
    func test_largeAndOldFiles_haveNoGroup() {
        XCTAssertNil(CleanupGroup.group(for: .largeFile))
        XCTAssertNil(CleanupGroup.group(for: .oldFile))
    }

    func test_group_forCategory_resolvesExpectedBuckets() {
        XCTAssertEqual(CleanupGroup.group(for: .systemCache), .systemJunk)
        XCTAssertEqual(CleanupGroup.group(for: .mailAttachments), .systemJunk)
        XCTAssertEqual(CleanupGroup.group(for: .trash), .trashBins)
        XCTAssertEqual(CleanupGroup.group(for: .xcodeJunk), .xcodeJunk)
        XCTAssertEqual(CleanupGroup.group(for: .webDevJunk), .webDevJunk)
        XCTAssertEqual(CleanupGroup.group(for: .documentVersions), .documentVersions)
    }

    // MARK: - Presentation contract

    /// Direct Clean is offered only on System Junk and Trash Bins, matching the
    /// reference design (Xcode Junk and Document Versions are review-only).
    func test_allowsDirectClean_matchesReference() {
        XCTAssertTrue(CleanupGroup.systemJunk.allowsDirectClean)
        XCTAssertTrue(CleanupGroup.trashBins.allowsDirectClean)
        XCTAssertFalse(CleanupGroup.xcodeJunk.allowsDirectClean)
        XCTAssertFalse(CleanupGroup.webDevJunk.allowsDirectClean)
        XCTAssertFalse(CleanupGroup.documentVersions.allowsDirectClean)
    }

    func test_titleBlurbBadge_nonEmptyForEveryGroup() {
        for group in CleanupGroup.allCases {
            XCTAssertFalse(group.title.isEmpty, "\(group.rawValue) title empty")
            XCTAssertFalse(group.blurb.isEmpty, "\(group.rawValue) blurb empty")
            XCTAssertFalse(group.badgeAsset.isEmpty, "\(group.rawValue) badge asset empty")
        }
    }

    /// Each badge asset name must resolve to a real image in the app bundle's
    /// asset catalog — guards against a card rendering a blank glyph.
    func test_badgeAsset_resolvesToAnImageInTheBundle() {
        for group in CleanupGroup.allCases {
            XCTAssertNotNil(
                NSImage(named: group.badgeAsset),
                "Asset catalog is missing badge \"\(group.badgeAsset)\" for \(group.rawValue)"
            )
        }
    }

    /// Display order leads with the hero.
    func test_displayOrder_systemJunkLeads() {
        XCTAssertEqual(CleanupGroup.allCases.first, .systemJunk)
    }

    /// A card's Review deep-links to its manager sub-category; the System Junk
    /// umbrella opens its section at the default first category (nil).
    func test_managerCategory_deepLinkTargets() {
        // System Junk opens to a category in its own group, not a sibling card's.
        XCTAssertEqual(CleanupGroup.systemJunk.managerCategory, .userCache)
        XCTAssertTrue(CleanupGroup.systemJunk.categories.contains(.userCache))
        XCTAssertEqual(CleanupGroup.trashBins.managerCategory, .trash)
        XCTAssertEqual(CleanupGroup.xcodeJunk.managerCategory, .xcodeJunk)
        XCTAssertEqual(CleanupGroup.webDevJunk.managerCategory, .webDevJunk)
        XCTAssertEqual(CleanupGroup.documentVersions.managerCategory, .documentVersions)
    }

    // MARK: - Tile aggregation

    func test_tiles_aggregatesCategoriesIntoGroupsWithSummedBytes() {
        let cacheA = file("a", size: 100, category: .userCache)
        let cacheB = file("b", size: 200, category: .systemCache)
        let mail = file("m", size: 50, category: .mailAttachments)
        let trash = file("t", size: 400, category: .trash)
        let xcode = file("x", size: 1_000, category: .xcodeJunk)
        let result = ScanResult(items: [cacheA, cacheB, mail, trash, xcode])

        let tiles = CleanupGroupTile.tiles(from: result)

        // System Junk rolls up the three caches/mail into one card.
        let systemJunk = tiles.first { $0.group == .systemJunk }
        XCTAssertEqual(systemJunk?.count, 3)
        XCTAssertEqual(systemJunk?.totalBytes, 350)

        let trashTile = tiles.first { $0.group == .trashBins }
        XCTAssertEqual(trashTile?.totalBytes, 400)

        let xcodeTile = tiles.first { $0.group == .xcodeJunk }
        XCTAssertEqual(xcodeTile?.totalBytes, 1_000)
    }

    /// Groups with no scanned files produce no tile.
    func test_tiles_omitsEmptyGroups() {
        let result = ScanResult(items: [file("t", size: 10, category: .trash)])

        let tiles = CleanupGroupTile.tiles(from: result)

        XCTAssertEqual(tiles.map(\.group), [.trashBins])
    }

    /// Tiles come back in display order, hero first.
    func test_tiles_areInDisplayOrder() {
        let result = ScanResult(items: [
            file("d", size: 1, category: .documentVersions),
            file("c", size: 1, category: .userCache),
            file("t", size: 1, category: .trash),
            file("x", size: 1, category: .xcodeJunk),
        ])

        let tiles = CleanupGroupTile.tiles(from: result)

        XCTAssertEqual(tiles.map(\.group), [.systemJunk, .trashBins, .xcodeJunk, .documentVersions])
    }

    // MARK: - Helpers

    private func file(_ name: String, size: Int64, category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/cleanup-group-tests/\(category.rawValue)/\(name)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }
}
