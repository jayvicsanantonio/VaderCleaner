// CleanupCardTests.swift
// Pins the Cleanup card typography contract: hero and wide cards lead with the reference's large bold size-led title while compact cards keep the denser headline.

import XCTest
import SwiftUI
@testable import VaderCleaner

final class CleanupCardTests: XCTestCase {

    func test_titleFont_isLargeAndBoldForHeroAndWideCards() {
        // The reference tiles lead with a big bold "34.4 GB of System Junk
        // Found" headline; both the hero and the wide card have room for it.
        XCTAssertEqual(CleanupCard.titleFont(for: .hero), .title2.weight(.bold))
        XCTAssertEqual(CleanupCard.titleFont(for: .wide), .title2.weight(.bold))
    }

    func test_titleFont_staysHeadlineForCompactCards() {
        // Compact cards sit two-up in a row; the denser headline keeps their
        // size-led titles from wrapping at the grid's narrowest widths.
        XCTAssertEqual(CleanupCard.titleFont(for: .compact), .headline)
    }
}
