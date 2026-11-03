// DashboardGridLayoutTests.swift
// Pins the bento geometry every section dashboard shares: a lead tile in the first of three columns, a wide tile over rows of pairs in the other two, and tiles that never overlap or leave the pane.

import CoreGraphics
import Testing
@testable import VaderCleanerCore

@Suite
struct DashboardGridLayoutTests {

    /// 992 wide leaves exactly 960 for three columns after two 16pt gaps, so
    /// every expected edge below is a whole number.
    private let pane = CGSize(width: 992, height: 416)

    @Test
    func noTiles_hasNoSlots() {
        #expect(DashboardGridLayout.slots(count: 0, in: pane).isEmpty)
    }

    @Test
    func oneTile_fillsThePaneAsTheLead() {
        let slots = DashboardGridLayout.slots(count: 1, in: pane)

        #expect(slots == [DashboardGridSlot(frame: CGRect(x: 0, y: 0, width: 992, height: 416), role: .lead)])
    }

    @Test
    func twoTiles_leadTakesTheFirstColumnAndTheOtherSpansTheRest() {
        let slots = DashboardGridLayout.slots(count: 2, in: pane)

        #expect(slots == [
            DashboardGridSlot(frame: CGRect(x: 0, y: 0, width: 320, height: 416), role: .lead),
            DashboardGridSlot(frame: CGRect(x: 336, y: 0, width: 656, height: 416), role: .wide),
        ])
    }

    @Test
    func threeTiles_stackTwoWideRowsBesideTheLead() {
        let slots = DashboardGridLayout.slots(count: 3, in: pane)

        #expect(slots == [
            DashboardGridSlot(frame: CGRect(x: 0, y: 0, width: 320, height: 416), role: .lead),
            DashboardGridSlot(frame: CGRect(x: 336, y: 0, width: 656, height: 200), role: .wide),
            DashboardGridSlot(frame: CGRect(x: 336, y: 216, width: 656, height: 200), role: .wide),
        ])
    }

    @Test
    func fourTiles_putAWideTileOverAPairAlignedToTheColumns() {
        let slots = DashboardGridLayout.slots(count: 4, in: pane)

        #expect(slots == [
            DashboardGridSlot(frame: CGRect(x: 0, y: 0, width: 320, height: 416), role: .lead),
            DashboardGridSlot(frame: CGRect(x: 336, y: 0, width: 656, height: 200), role: .wide),
            DashboardGridSlot(frame: CGRect(x: 336, y: 216, width: 320, height: 200), role: .compact),
            DashboardGridSlot(frame: CGRect(x: 672, y: 216, width: 320, height: 200), role: .compact),
        ])
        // The pair shares the lead's column width, so all three columns line up.
        #expect(slots[2].frame.width == slots[0].frame.width)
    }

    @Test
    func moreTilesThanTheSelectorShows_stillFitWithoutOverlapping() {
        let slots = DashboardGridLayout.slots(count: 5, in: pane)

        #expect(slots.map(\.role) == [.lead, .wide, .compact, .compact, .wide])
        let bounds = CGRect(origin: .zero, size: pane)
        for slot in slots {
            #expect(bounds.contains(slot.frame))
        }
        for (index, slot) in slots.enumerated() {
            for other in slots[(index + 1)...] {
                #expect(!slot.frame.intersects(other.frame))
            }
        }
    }

    @Test
    func aPaneSmallerThanTheGaps_neverProducesNegativeSizes() {
        let slots = DashboardGridLayout.slots(count: 4, in: CGSize(width: 10, height: 10))

        #expect(slots.count == 4)
        for slot in slots {
            #expect(slot.frame.width >= 0)
            #expect(slot.frame.height >= 0)
        }
    }
}
