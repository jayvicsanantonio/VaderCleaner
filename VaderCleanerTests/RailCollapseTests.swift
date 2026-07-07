// RailCollapseTests.swift
// Pins the navigation rail's collapse rule: icons-only while the active section is out of its intro, and latched collapsed for the rest of the session once that has happened even once.

import XCTest
@testable import VaderCleaner

final class RailCollapseTests: XCTestCase {

    func testRailStaysExpandedOnAnIntroBeforeAnyCollapse() {
        XCTAssertFalse(ContentView.railCollapsed(
            activePresentation: .intro, collapsedOnceThisSession: false
        ))
    }

    func testRailStaysExpandedOnANonScannableSectionBeforeAnyCollapse() {
        // Health Monitor has no scan flow (nil presentation) and keeps the
        // expanded rail until some section has collapsed it.
        XCTAssertFalse(ContentView.railCollapsed(
            activePresentation: nil, collapsedOnceThisSession: false
        ))
    }

    func testRailCollapsesWhenTheActiveSectionLeavesItsIntro() {
        XCTAssertTrue(ContentView.railCollapsed(
            activePresentation: .working, collapsedOnceThisSession: false
        ))
        XCTAssertTrue(ContentView.railCollapsed(
            activePresentation: .results, collapsedOnceThisSession: false
        ))
    }

    func testRailStaysCollapsedForTheSessionOnceLatched() {
        // Returning to an intro (Start Over) or a non-scannable section no
        // longer re-expands the rail once any section has collapsed it.
        XCTAssertTrue(ContentView.railCollapsed(
            activePresentation: .intro, collapsedOnceThisSession: true
        ))
        XCTAssertTrue(ContentView.railCollapsed(
            activePresentation: nil, collapsedOnceThisSession: true
        ))
        XCTAssertTrue(ContentView.railCollapsed(
            activePresentation: .results, collapsedOnceThisSession: true
        ))
    }
}
