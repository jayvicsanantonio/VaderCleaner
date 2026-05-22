// ScanDiscWindowFrameTests.swift
// Pins the pure geometry that positions the floating Scan disc's child panel: centered over the detail area and either straddling or tucked above the main window's bottom edge.

import XCTest
@testable import VaderCleaner

final class ScanDiscWindowFrameTests: XCTestCase {

    private let parent = CGRect(x: 100, y: 200, width: 1000, height: 800)
    private let railWidth: CGFloat = 240
    private let panelSize: CGFloat = 190
    private let discDiameter: CGFloat = 108

    // MARK: Straddle

    func test_straddle_centersPanelVerticallyOnBottomEdge() {
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent,
            railWidth: railWidth,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: .straddleBottomEdge
        )
        // The disc is centered in its panel, so a panel centered on the
        // parent's bottom edge puts the disc's center exactly on the edge —
        // top half inside the window, bottom half over the desktop.
        XCTAssertEqual(frame.midY, parent.minY, accuracy: 0.001,
                       "Panel center must sit on the parent window's bottom edge")
        XCTAssertEqual(frame.height, panelSize, accuracy: 0.001)
        XCTAssertEqual(frame.width, panelSize, accuracy: 0.001)
    }

    func test_straddle_centersPanelHorizontallyOverDetailArea() {
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent,
            railWidth: railWidth,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: .straddleBottomEdge
        )
        // The disc centers over the detail content area — the window minus the
        // navigation rail — not the full window.
        let detailMidX = parent.minX + railWidth + (parent.width - railWidth) / 2
        XCTAssertEqual(frame.midX, detailMidX, accuracy: 0.001,
                       "Panel must center over the detail area, clear of the rail")
    }

    func test_horizontalCentering_withoutRail_matchesWindowCenter() {
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent,
            railWidth: 0,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: .straddleBottomEdge
        )
        XCTAssertEqual(frame.midX, parent.midX, accuracy: 0.001,
                       "With no rail the disc centers on the whole window")
    }

    // MARK: Tucked inside (fullscreen)

    func test_tucked_placesDiscFullyInsideAboveTheEdge() {
        let margin: CGFloat = 40
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent,
            railWidth: railWidth,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: .tuckedInside(margin: margin)
        )
        // The disc's bottom edge must sit `margin` above the window's bottom
        // edge, so the whole disc is on-window (used in fullscreen, where
        // there is no "outside" to straddle into).
        let discBottom = frame.midY - discDiameter / 2
        XCTAssertEqual(discBottom, parent.minY + margin, accuracy: 0.001,
                       "Tucked disc bottom must sit `margin` above the window edge")
    }

    func test_tucked_keepsDiscWithinParentVerticalBounds() {
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent,
            railWidth: railWidth,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: .tuckedInside(margin: 40)
        )
        let discBottom = frame.midY - discDiameter / 2
        let discTop = frame.midY + discDiameter / 2
        XCTAssertGreaterThanOrEqual(discBottom, parent.minY,
                                    "Tucked disc must not cross below the window")
        XCTAssertLessThanOrEqual(discTop, parent.maxY,
                                 "Tucked disc must stay within the window")
    }

    func test_tucked_keepsTheSameHorizontalCentering() {
        let straddle = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent, railWidth: railWidth, panelSize: panelSize,
            discDiameter: discDiameter, placement: .straddleBottomEdge
        )
        let tucked = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent, railWidth: railWidth, panelSize: panelSize,
            discDiameter: discDiameter, placement: .tuckedInside(margin: 40)
        )
        XCTAssertEqual(straddle.midX, tucked.midX, accuracy: 0.001,
                       "Placement must change only the vertical position")
    }

    // MARK: Screen clamping

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func test_straddle_clampsDiscAboveTheScreenBottom() {
        // A window pushed against the screen's bottom edge — an unclamped
        // straddle would drop the disc's lower half off-screen / behind the
        // Dock. The disc must stay fully on the visible screen.
        let lowWindow = CGRect(x: 100, y: 24, width: 1000, height: 800)
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: lowWindow,
            railWidth: railWidth,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: .straddleBottomEdge,
            screenVisibleFrame: screen
        )
        let discInset = (panelSize - discDiameter) / 2
        let discBottom = frame.minY + discInset
        XCTAssertGreaterThanOrEqual(discBottom, screen.minY,
                                    "The disc must not drop below the visible screen")
    }

    func test_straddle_doesNotClampWhenWindowIsWellWithinScreen() {
        // A normally-placed window: clamping must be a no-op so the disc still
        // straddles the bottom edge exactly.
        let unclamped = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent, railWidth: railWidth, panelSize: panelSize,
            discDiameter: discDiameter, placement: .straddleBottomEdge
        )
        let clamped = ScanDiscWindowFrame.panelFrame(
            parentFrame: parent, railWidth: railWidth, panelSize: panelSize,
            discDiameter: discDiameter, placement: .straddleBottomEdge,
            screenVisibleFrame: screen
        )
        XCTAssertEqual(clamped, unclamped,
                       "A window clear of the screen edge must not be clamped")
    }
}
