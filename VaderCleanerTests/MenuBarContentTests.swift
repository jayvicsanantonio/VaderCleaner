// MenuBarContentTests.swift
// Pins where the menu bar panel's actions lead: each attention step's section, and the verb shortcuts with their labels.

import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

@MainActor
@Suite struct MenuBarContentTests {

    /// Every attention step lands in the section that can fix it.
    @Test(arguments: [
        (MenuBarViewModel.NextStep.Target.threats, NavigationSection.malwareRemoval),
        (.cleanup, .systemJunk),
        (.performance, .performance),
        (.smartScan, .smartScan),
    ])
    func eachStepOpensTheSectionThatFixesIt(target: MenuBarViewModel.NextStep.Target, section: NavigationSection) {
        #expect(MenuBarContent.section(for: target) == section)
    }

    /// The shortcuts follow the rail's order and none repeats a reading tile's
    /// destination except Cleanup, which Storage shares on purpose.
    @Test func quickActionsFollowTheRail() {
        #expect(MenuBarContent.quickActionSections == [.smartScan, .systemJunk, .applications, .spaceLens])
        let railOrder = NavigationSection.allCases
        let positions = MenuBarContent.quickActionSections.compactMap { railOrder.firstIndex(of: $0) }
        #expect(positions == positions.sorted())
    }

    /// Shortcuts are named for what they do, not where they live.
    @Test(arguments: [
        (NavigationSection.smartScan, "Smart Scan"),
        (.systemJunk, "Clean Up"),
        (.applications, "Uninstall"),
        (.spaceLens, "Space Lens"),
    ])
    func quickActionsAreVerbs(section: NavigationSection, label: String) {
        #expect(MenuBarContent.quickActionLabel(for: section) == label)
    }
}
