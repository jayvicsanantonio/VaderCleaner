// MyClutterThumbnailStripItemTests.swift
// Verifies the emphasis precedence for a Duplicates/Similar-Images thumbnail: selected (active) outranks focused, focused outranks hover, hover outranks idle.

import XCTest
@testable import VaderCleaner

final class MyClutterThumbnailStripItemTests: XCTestCase {

    func test_selected_isActive_regardlessOfFocusOrHover() {
        XCTAssertEqual(
            ClutterThumbnailEmphasis.resolve(isSelected: true, isFocused: true, hovered: true),
            .selected
        )
        XCTAssertEqual(
            ClutterThumbnailEmphasis.resolve(isSelected: true, isFocused: false, hovered: false),
            .selected
        )
    }

    func test_focused_outranksHover_whenNotSelected() {
        XCTAssertEqual(
            ClutterThumbnailEmphasis.resolve(isSelected: false, isFocused: true, hovered: true),
            .focused
        )
    }

    func test_hovered_whenOnlyHovered() {
        XCTAssertEqual(
            ClutterThumbnailEmphasis.resolve(isSelected: false, isFocused: false, hovered: true),
            .hovered
        )
    }

    func test_idle_whenNoStateApplies() {
        XCTAssertEqual(
            ClutterThumbnailEmphasis.resolve(isSelected: false, isFocused: false, hovered: false),
            .idle
        )
    }
}
