// DashboardCardTests.swift
// Pins the rules every section dashboard's cards share: title size by role, the glass-then-white button order, and an orb palette per section that matches the baked badges.

import SwiftUI
import Testing
import VaderCleanerCore
@testable import VaderCleaner

@MainActor
@Suite
struct DashboardCardTests {

    @Test
    func leadAndWideTiles_leadWithTheLargerTitle() {
        #expect(DashboardCard<EmptyView, EmptyView>.titleFont(for: .lead) == .title3.weight(.semibold))
        #expect(DashboardCard<EmptyView, EmptyView>.titleFont(for: .wide) == .title3.weight(.semibold))
    }

    @Test
    func compactTiles_keepTheDenserHeadline() {
        // Compact tiles sit two-up; the denser headline keeps their titles from
        // wrapping at the grid's narrowest widths.
        #expect(DashboardCard<EmptyView, EmptyView>.titleFont(for: .compact) == .headline)
    }

    @Test
    func theWhiteCapsule_alwaysSitsAtTheTrailingEdge() {
        let remove = DashboardCardAction(title: "Remove", prominence: .primary, identifier: "remove", action: {})
        let review = DashboardCardAction(title: "Review", prominence: .secondary, identifier: "review", action: {})

        let ordered = DashboardCard<EmptyView, EmptyView>.orderedActions([remove, review])

        #expect(ordered.map(\.identifier) == ["review", "remove"])
    }

    @Test
    func eachDashboardSection_wearsItsOwnOrbColour() {
        let sections: [NavigationSection] = [.systemJunk, .largeOldFiles, .malwareRemoval, .performance, .applications]
        let palettes = sections.map(DashboardOrbPalette.for)

        for (index, palette) in palettes.enumerated() {
            #expect(!palettes[(index + 1)...].contains(palette))
        }
    }

    @Test
    func drawnOrbs_matchTheBakedBadgesInTheSameSection() {
        // Cleanup's cards wear the baked green badges and Protection's manager
        // the baked pink ones; a drawn orb beside them must use the same stops.
        #expect(DashboardOrbPalette.for(.systemJunk) == .green)
        #expect(DashboardOrbPalette.for(.malwareRemoval) == .pink)
        #expect(DashboardOrbPalette.for(.performance) == .orange)
        #expect(DashboardOrbPalette.for(.applications) == .blue)
    }
}
