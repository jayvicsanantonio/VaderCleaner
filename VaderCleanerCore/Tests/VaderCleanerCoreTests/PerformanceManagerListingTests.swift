// PerformanceManagerListingTests.swift
// Pins what the Performance Manager shows for a search and that a bulk action only ever reaches rows the user can see.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct PerformanceManagerListingTests {

    @Test
    func items_withNoQueryReturnsEverythingSortedByTitle() {
        let items = [Self.item("zoom"), Self.item("Adobe"), Self.item("docker")]

        let listed = PerformanceManagerListing.items(items, matching: "")

        #expect(listed.map(\.title) == ["Adobe", "docker", "zoom"])
    }

    @Test
    func items_matchTheSubtitleAsWellAsTheTitle() {
        let items = [
            Self.item("com.acme.updater", subtitle: "/Applications/Zoom.app/updater"),
            Self.item("com.other.agent", subtitle: "/usr/local/bin/other")
        ]

        let listed = PerformanceManagerListing.items(items, matching: "zoom")

        #expect(listed.map(\.title) == ["com.acme.updater"])
    }

    @Test
    func tasks_matchTheSummaryAsWellAsTheTitle() throws {
        let dns = try #require(MaintenanceTask.catalog.first { $0.kind == .flushDNS })

        let listed = PerformanceManagerListing.tasks(MaintenanceTask.catalog, matching: "stale lookups")

        #expect(listed == [dns])
    }

    @Test
    func actionableSelection_dropsRowsHiddenBySearch() {
        let actionable = PerformanceManagerListing.actionableSelection(
            ["visible", "hidden"],
            visibleIDs: ["visible", "unselected"]
        )

        #expect(actionable == ["visible"])
    }

    @Test
    func selectAll_onlyAddsVisibleRows() {
        let selection = PerformanceManagerListing.selectingAll(
            in: ["earlier"],
            visibleIDs: ["visible"]
        )

        #expect(selection == ["earlier", "visible"])
    }

    @Test
    func deselectAll_leavesHiddenSelectionAlone() {
        let selection = PerformanceManagerListing.deselectingAll(
            in: ["earlier", "visible"],
            visibleIDs: ["visible"]
        )

        #expect(selection == ["earlier"])
    }

    @Test
    func confirmationList_namesEveryItemWhenShort() {
        let list = PerformanceManagerListing.confirmationList(names: ["b", "a"], limit: 3)

        #expect(list == "a\nb")
    }

    @Test
    func confirmationList_saysHowManyMoreWhenLong() {
        let list = PerformanceManagerListing.confirmationList(names: ["a", "b", "c", "d", "e"], limit: 3)

        #expect(list == "a\nb\nc\nand 2 more")
    }

    private static func item(_ title: String, subtitle: String? = nil) -> ManagerItem {
        ManagerItem(
            id: title,
            title: title,
            subtitle: subtitle,
            size: nil,
            sizeText: nil,
            systemImage: "gearshape",
            tint: .secondary
        )
    }
}
