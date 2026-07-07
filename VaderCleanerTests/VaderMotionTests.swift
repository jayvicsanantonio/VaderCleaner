// VaderMotionTests.swift
// Unit tests for VaderMotion's pure press-scale helper — the control-press shrink and its Reduce Motion opt-out.

import XCTest
import SwiftUI
@testable import VaderCleaner

final class VaderMotionTests: XCTestCase {

    func testPressedControlShrinksToThePressedScale() {
        XCTAssertEqual(
            VaderMotion.pressScale(isPressed: true, reduceMotion: false),
            VaderMotion.pressedScale
        )
    }

    func testPressedScaleIsAGentleShrinkNotACollapse() {
        // The Tahoe press reads as a subtle dip: visibly smaller than full
        // size, but never below 90% where the label would swim.
        XCTAssertLessThan(VaderMotion.pressedScale, 1)
        XCTAssertGreaterThanOrEqual(VaderMotion.pressedScale, 0.9)
    }

    func testUnpressedControlStaysAtFullSize() {
        XCTAssertEqual(VaderMotion.pressScale(isPressed: false, reduceMotion: false), 1)
    }

    func testReduceMotionPinsThePressedControlAtFullSize() {
        XCTAssertEqual(VaderMotion.pressScale(isPressed: true, reduceMotion: true), 1)
    }

    func testReduceMotionAndUnpressedStaysAtFullSize() {
        XCTAssertEqual(VaderMotion.pressScale(isPressed: false, reduceMotion: true), 1)
    }

    func testManagerZoomRunsOnItsOwnClock() {
        // The manager zoom is a quick snappy spring — distinct from the
        // general surface spring so opening a manager feels like a response,
        // not choreography. Pinned so the two can't silently collapse back
        // into one timing.
        XCTAssertEqual(VaderMotion.managerZoom, .snappy(duration: 0.4))
        XCTAssertNotEqual(VaderMotion.managerZoom, VaderMotion.surface)
    }
}
