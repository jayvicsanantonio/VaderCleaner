// SmartScanReviewManagerSelectionTests.swift
// Verifies the manager's uniform-selection fast path: a category tally that reports everything (or nothing) selected answers every row checkbox in O(1), and only a mixed tally falls back to the per-row check.

import XCTest
@testable import VaderCleaner

final class SmartScanReviewManagerSelectionTests: XCTestCase {

    /// Everything in the category selected → every row is checked without a
    /// per-row walk.
    func test_uniformSelection_allSelected_isTrue() {
        XCTAssertEqual(SmartScanReviewManager.uniformSelection(tally: (selected: 5, total: 5)), true)
    }

    /// A tally that over-counts (a stale total racing a selection change) still
    /// reads as fully selected rather than falling back to the slow walk.
    func test_uniformSelection_overCount_isTrue() {
        XCTAssertEqual(SmartScanReviewManager.uniformSelection(tally: (selected: 6, total: 5)), true)
    }

    /// Nothing selected → every row is unchecked without a per-row walk.
    func test_uniformSelection_noneSelected_isFalse() {
        XCTAssertEqual(SmartScanReviewManager.uniformSelection(tally: (selected: 0, total: 5)), false)
    }

    /// A mixed tally can't answer per-row; the caller's check must run.
    func test_uniformSelection_partial_isNil() {
        XCTAssertNil(SmartScanReviewManager.uniformSelection(tally: (selected: 2, total: 5)))
    }

    /// No tally (the small flat managers) or an empty category → no fast path.
    func test_uniformSelection_missingOrEmptyTally_isNil() {
        XCTAssertNil(SmartScanReviewManager.uniformSelection(tally: nil))
        XCTAssertNil(SmartScanReviewManager.uniformSelection(tally: (selected: 0, total: 0)))
    }

    // MARK: - Footer summary text

    /// Nothing selected drops the size clause — no "· 0 bytes" tail — even when
    /// the caller reports a (zero) byte total for the category.
    func test_footer_nothingSelected_hidesSizeClause() {
        let text = SmartScanReviewManager.selectionFooterText(.init(count: 0, bytes: 0))
        XCTAssertEqual(text, "No Items Selected")
    }

    /// Nothing selected with no byte total likewise shows the count alone.
    func test_footer_nothingSelected_nilBytes() {
        let text = SmartScanReviewManager.selectionFooterText(.init(count: 0, bytes: nil))
        XCTAssertEqual(text, "No Items Selected")
    }

    /// A selection with a byte total shows the count and a "· size" clause.
    func test_footer_selectedWithBytes_showsSizeClause() {
        let text = SmartScanReviewManager.selectionFooterText(.init(count: 3, bytes: 5_400_000))
        XCTAssertEqual(text, "3 Items Selected  ·  5.4 MB")
    }

    /// A sizeless selection (e.g. app updates) shows the count with no clause.
    func test_footer_selectedNoBytes_countOnly() {
        let text = SmartScanReviewManager.selectionFooterText(.init(count: 2, bytes: nil))
        XCTAssertEqual(text, "2 Items Selected")
    }

    // MARK: - Pane collapse

    /// One always-selected section navigates nothing, so the left pane hides;
    /// two or more give a real choice and bring it back.
    func test_showsSectionPane_hiddenForSingleSection() {
        XCTAssertFalse(SmartScanReviewManager.showsSectionPane(sectionCount: 0))
        XCTAssertFalse(SmartScanReviewManager.showsSectionPane(sectionCount: 1))
        XCTAssertTrue(SmartScanReviewManager.showsSectionPane(sectionCount: 2))
    }

    /// In a single-section manager a lone category collapses the middle pane;
    /// two or more keep it.
    func test_showsCategoryPane_hiddenForSingleCategory() {
        XCTAssertFalse(SmartScanReviewManager.showsCategoryPane(categoryCount: 0, sectionCount: 1))
        XCTAssertFalse(SmartScanReviewManager.showsCategoryPane(categoryCount: 1, sectionCount: 1))
        XCTAssertTrue(SmartScanReviewManager.showsCategoryPane(categoryCount: 3, sectionCount: 1))
    }

    /// A hierarchical manager (more than one section) keeps the middle pane even
    /// while a single-category section is selected, so the column count stays
    /// stable as the user moves between sections.
    func test_showsCategoryPane_stableInMultiSectionManager() {
        XCTAssertTrue(SmartScanReviewManager.showsCategoryPane(categoryCount: 1, sectionCount: 3))
        XCTAssertTrue(SmartScanReviewManager.showsCategoryPane(categoryCount: 0, sectionCount: 3))
    }

    /// With the category pane visible, the item header shows only the category's
    /// own description — the section's line stays in the category pane.
    func test_itemHeaderDescription_categoryPaneShown_usesCategoryOnly() {
        XCTAssertEqual(
            SmartScanReviewManager.itemHeaderDescription(
                categoryDescription: "Files over 50 MB.",
                sectionDescription: "These are your files.",
                categoryPaneShown: true),
            "Files over 50 MB.")
        XCTAssertNil(
            SmartScanReviewManager.itemHeaderDescription(
                categoryDescription: nil,
                sectionDescription: "These are your files.",
                categoryPaneShown: true))
    }

    /// When the category pane is hidden, a category with no description falls
    /// back to the section's line so it isn't dropped (the Downloads case).
    func test_itemHeaderDescription_categoryPaneHidden_fallsBackToSection() {
        XCTAssertEqual(
            SmartScanReviewManager.itemHeaderDescription(
                categoryDescription: nil,
                sectionDescription: "These are your files.",
                categoryPaneShown: false),
            "These are your files.")
    }

    /// The category's own description still wins over the section's when both
    /// exist and the pane is hidden.
    func test_itemHeaderDescription_categoryWinsWhenBothPresent() {
        XCTAssertEqual(
            SmartScanReviewManager.itemHeaderDescription(
                categoryDescription: "Detected threats.",
                sectionDescription: "Protection.",
                categoryPaneShown: false),
            "Detected threats.")
    }

    // MARK: - Locked (kept best shot) rows

    /// A locked row — a similar-photo group's kept best shot — is never among
    /// the toggleable items, so Select All and the bulk-select state can't
    /// sweep it into a deletion.
    func test_selectableItems_excludesLockedRows() {
        let kept = ManagerItem(
            id: "/photos/best.jpg", title: "best.jpg", subtitle: nil,
            size: 100, sizeText: "100 bytes", systemImage: "photo.fill",
            tint: .blue, usesThumbnail: true, isLocked: true
        )
        let copy = ManagerItem(
            id: "/photos/copy.jpg", title: "copy.jpg", subtitle: nil,
            size: 90, sizeText: "90 bytes", systemImage: "photo.fill",
            tint: .blue, usesThumbnail: true
        )
        let selectable = SmartScanReviewManager.selectableItems([kept, copy])
        XCTAssertEqual(selectable.map(\.id), ["/photos/copy.jpg"])
    }
}
