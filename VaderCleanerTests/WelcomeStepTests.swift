// WelcomeStepTests.swift
// Pins the first-run flow's step order, navigation arithmetic, and the per-step content each step renders.

import XCTest
@testable import VaderCleaner

@MainActor
final class WelcomeStepTests: XCTestCase {

    func test_allCases_areInPresentationOrder() {
        XCTAssertEqual(
            WelcomeStep.allCases,
            [.welcome, .clean, .protect, .tune, .access, .ready]
        )
    }

    func test_first_isWelcome() {
        XCTAssertEqual(WelcomeStep.first, .welcome)
    }

    func test_last_isReady() {
        XCTAssertEqual(WelcomeStep.last, .ready)
    }

    func test_next_walksForwardAndStopsAtTheEnd() {
        XCTAssertEqual(WelcomeStep.welcome.next, .clean)
        XCTAssertEqual(WelcomeStep.tune.next, .access)
        XCTAssertNil(WelcomeStep.ready.next)
    }

    func test_previous_walksBackwardAndStopsAtTheStart() {
        XCTAssertEqual(WelcomeStep.ready.previous, .access)
        XCTAssertEqual(WelcomeStep.clean.previous, .welcome)
        XCTAssertNil(WelcomeStep.welcome.previous)
    }

    func test_isTour_marksOnlyTheThreeCapabilitySteps() {
        XCTAssertEqual(
            WelcomeStep.allCases.filter(\.isTour),
            [.clean, .protect, .tune]
        )
    }

    func test_progress_runsFromZeroToOneAcrossTheFlow() {
        XCTAssertEqual(WelcomeStep.welcome.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(WelcomeStep.ready.progress, 1, accuracy: 0.0001)
        // Monotonic in between, so the progress rail never travels backwards.
        let values = WelcomeStep.allCases.map(\.progress)
        XCTAssertEqual(values, values.sorted())
    }

    func test_accessibilityIdentifiers_areStableAndUnique() {
        let identifiers = WelcomeStep.allCases.map(\.accessibilityIdentifier)
        XCTAssertEqual(identifiers.first, "welcome.step.welcome")
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func test_everyStep_hasHeadlineAndTagline() {
        for step in WelcomeStep.allCases {
            let content = step.content
            XCTAssertFalse(content.title.isEmpty, "\(step) has no title")
            XCTAssertFalse(content.tagline.isEmpty, "\(step) has no tagline")
            XCTAssertFalse(content.heroSymbol.isEmpty, "\(step) has no fallback symbol")
        }
    }

    func test_tourSteps_listTheFeaturesTheySell() {
        for step in WelcomeStep.allCases where step.isTour {
            XCTAssertFalse(step.content.features.isEmpty, "\(step) sells nothing")
        }
    }

    func test_tourSteps_eachAdoptADistinctSectionHue() {
        let accents = WelcomeStep.allCases
            .filter(\.isTour)
            .map { $0.content.theme.accent }
        XCTAssertEqual(Set(accents).count, accents.count)
    }

    func test_bookendSteps_wearTheSmartScanIdentity() {
        // The flow opens and closes in the app's own violet, so the first-run
        // experience is framed by Smart Scan — where it hands the user off.
        XCTAssertEqual(WelcomeStep.welcome.content.theme, NavigationSection.smartScan.theme)
        XCTAssertEqual(WelcomeStep.ready.content.theme, NavigationSection.smartScan.theme)
    }
}
