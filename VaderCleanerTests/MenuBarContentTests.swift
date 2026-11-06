// MenuBarContentTests.swift
// Pins where the menu bar panel's actions lead: each attention step opens the section that can fix it.

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
}
