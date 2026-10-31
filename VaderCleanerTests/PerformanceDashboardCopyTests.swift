// PerformanceDashboardCopyTests.swift
// Pins the Performance dashboard's singular card titles and that its reassurance never claims all is well beside a finding.

import Testing
@testable import VaderCleaner

@MainActor
@Suite
struct PerformanceDashboardCopyTests {

    @Test
    func titles_useTheSingularForOne() {
        #expect(PerformanceDashboardView.loginItemsTitle(count: 1) == "You Have 1 Login Item")
        #expect(PerformanceDashboardView.backgroundItemsTitle(count: 1) == "1 Background Item Found")
        #expect(PerformanceDashboardView.maintenanceTitle(count: 1) == "1 Maintenance Task Recommended")
    }

    @Test
    func titles_usePluralForMany() {
        #expect(PerformanceDashboardView.loginItemsTitle(count: 2) == "You Have 2 Login Items")
        #expect(PerformanceDashboardView.backgroundItemsTitle(count: 2) == "2 Background Items Found")
        #expect(PerformanceDashboardView.maintenanceTitle(count: 2) == "2 Maintenance Tasks Recommended")
    }

    @Test
    func reassurance_saysNothingNeedsAttentionOnlyWithNoFindings() {
        #expect(PerformanceDashboardView.reassurance(forFindingCount: 0).map(\.id).contains("performance.tuned"))
        #expect(!PerformanceDashboardView.reassurance(forFindingCount: 1).map(\.id).contains("performance.tuned"))
        #expect(!PerformanceDashboardView.reassurance(forFindingCount: 1).isEmpty)
    }
}
