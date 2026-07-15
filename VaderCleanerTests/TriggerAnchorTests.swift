// TriggerAnchorTests.swift
// Pins the click-to-anchor mapping for the manager zoom (pane-relative unit coordinates, clamping, center fallback) and the press registry the button styles feed.

import XCTest
import SwiftUI
@testable import VaderCleaner

final class TriggerAnchorTests: XCTestCase {

    /// A detail pane sitting to the right of the navigation rail, matching
    /// how the transition host is framed in window space.
    private let pane = CGRect(x: 240, y: 0, width: 900, height: 700)

    func testPointAtPaneCenterMapsToCenterAnchor() {
        let anchor = TriggerAnchor.unitPoint(for: CGPoint(x: 690, y: 350), in: pane)
        XCTAssertEqual(anchor.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.5, accuracy: 0.0001)
    }

    func testPointMapsRelativeToThePaneOriginNotTheWindow() {
        // A click near the pane's top-leading corner is a small unit value
        // even though its window x is large — the rail offset must not leak
        // into the anchor.
        let anchor = TriggerAnchor.unitPoint(for: CGPoint(x: 330, y: 70), in: pane)
        XCTAssertEqual(anchor.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.1, accuracy: 0.0001)
    }

    /// The box stores frame updates by reference: geometry callbacks write
    /// into the same instance the click handlers read, so tracking a frame
    /// never re-renders the view that owns it.
    func testFrameBoxStoresLatestRect() {
        let box = FrameBox()
        XCTAssertEqual(box.rect, .zero)
        box.rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(box.rect, CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testCornersMapToUnitCorners() {
        XCTAssertEqual(TriggerAnchor.unitPoint(for: CGPoint(x: 240, y: 0), in: pane), UnitPoint(x: 0, y: 0))
        XCTAssertEqual(TriggerAnchor.unitPoint(for: CGPoint(x: 1140, y: 700), in: pane), UnitPoint(x: 1, y: 1))
    }

    func testPointsOutsideThePaneAreClampedToItsEdges() {
        let outside = TriggerAnchor.unitPoint(for: CGPoint(x: 100, y: 900), in: pane)
        XCTAssertEqual(outside.x, 0)
        XCTAssertEqual(outside.y, 1)
    }

    func testDegeneratePaneFallsBackToTheCenterAnchor() {
        let anchor = TriggerAnchor.unitPoint(for: CGPoint(x: 100, y: 100), in: .zero)
        XCTAssertEqual(anchor, .center)
    }
}

/// Pins the press registry the button styles feed: a fresh press is consumed
/// exactly once, and stale presses are ignored.
@MainActor
final class TriggerPressRegistryTests: XCTestCase {

    func testFreshPressIsConsumedExactlyOnce() {
        let registry = TriggerPressRegistry()
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        let now = Date()
        registry.recordPress(frame: frame, at: now)
        XCTAssertEqual(registry.consumeRecentPress(at: now.addingTimeInterval(1)), frame)
        XCTAssertNil(registry.consumeRecentPress(at: now.addingTimeInterval(1)))
    }

    func testStalePressIsIgnored() {
        let registry = TriggerPressRegistry()
        let now = Date()
        registry.recordPress(frame: CGRect(x: 0, y: 0, width: 10, height: 10), at: now)
        XCTAssertNil(registry.consumeRecentPress(
            at: now.addingTimeInterval(TriggerPressRegistry.freshness + 1)
        ))
    }

    func testLaterPressReplacesAnEarlierOne() {
        let registry = TriggerPressRegistry()
        let now = Date()
        registry.recordPress(frame: CGRect(x: 0, y: 0, width: 10, height: 10), at: now)
        let latest = CGRect(x: 5, y: 5, width: 20, height: 20)
        registry.recordPress(frame: latest, at: now.addingTimeInterval(0.2))
        XCTAssertEqual(registry.consumeRecentPress(at: now.addingTimeInterval(0.4)), latest)
    }
}
