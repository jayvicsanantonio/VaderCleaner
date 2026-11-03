// PerformanceDashboardCopyTests.swift
// Pins the Performance dashboard's headline and card titles in their singular and plural forms, and that its reassurance never claims all is well beside a finding.

import Testing
@testable import VaderCleaner

@MainActor
@Suite
struct PerformanceDashboardCopyTests {

    @Test
    func titles_useTheSingularForOne() {
        #expect(PerformanceDashboardView.loginItemsTitle(count: 1) == "1 Login Item Found")
        #expect(PerformanceDashboardView.backgroundItemsTitle(count: 1) == "1 Background Item Found")
        #expect(PerformanceDashboardView.maintenanceTitle(count: 1) == "1 Maintenance Task Recommended")
    }

    @Test
    func titles_usePluralForMany() {
        #expect(PerformanceDashboardView.loginItemsTitle(count: 2) == "2 Login Items Found")
        #expect(PerformanceDashboardView.backgroundItemsTitle(count: 2) == "2 Background Items Found")
        #expect(PerformanceDashboardView.maintenanceTitle(count: 2) == "2 Maintenance Tasks Recommended")
    }

    @Test
    func headline_countsEverythingTheCardsOfferToReview() {
        #expect(PerformanceDashboardView.headline(findingCount: 1) == "We've found 1 item to review on your Mac.")
        #expect(PerformanceDashboardView.headline(findingCount: 18) == "We've found 18 items to review on your Mac.")
    }

    @Test
    func headline_saysNothingNeedsAttentionWithNoFindings() {
        #expect(PerformanceDashboardView.headline(findingCount: 0) == "Nothing needs your attention right now.")
    }

    @Test
    func reassurance_saysNothingNeedsAttentionOnlyWithNoFindings() {
        #expect(PerformanceDashboardView.reassurance(forFindingCount: 0).map(\.id).contains("performance.tuned"))
        #expect(!PerformanceDashboardView.reassurance(forFindingCount: 1).map(\.id).contains("performance.tuned"))
        #expect(!PerformanceDashboardView.reassurance(forFindingCount: 1).isEmpty)
    }
}
