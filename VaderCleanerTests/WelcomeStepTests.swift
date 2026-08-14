// WelcomeStepTests.swift
// Pins the first-run flow's step order, navigation arithmetic, and the per-step content each step renders.

import XCTest
@testable import VaderCleaner

@MainActor
final class WelcomeStepTests: XCTestCase {

    func test_allCases_areInPresentationOrder() {
        XCTAssertEqual(
            WelcomeStep.allCases,
            [.welcome, .clean, .protect, .tune, .howItWorks, .access, .ready]
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
        XCTAssertEqual(WelcomeStep.tune.next, .howItWorks)
        XCTAssertEqual(WelcomeStep.howItWorks.next, .access)
        XCTAssertNil(WelcomeStep.ready.next)
    }

    func test_previous_walksBackwardAndStopsAtTheStart() {
        XCTAssertEqual(WelcomeStep.ready.previous, .access)
        XCTAssertEqual(WelcomeStep.clean.previous, .welcome)
        XCTAssertNil(WelcomeStep.welcome.previous)
    }

    func test_howItWorks_spellsOutTheThreeBeatLoop() {
        // The step exists to teach the loop the whole app runs on, so it must
        // actually name all three beats rather than gesturing at them.
        XCTAssertEqual(WelcomeStep.howItWorks.beats.count, 3)
        for beat in WelcomeStep.howItWorks.beats {
            XCTAssertFalse(beat.title.isEmpty)
            XCTAssertFalse(beat.detail.isEmpty)
            XCTAssertFalse(beat.symbol.isEmpty)
        }
    }

    func test_howItWorks_isNotSoldAsATourStop() {
        // It teaches rather than sells, so it carries no feature rows and
        // doesn't count toward the skippable tour.
        XCTAssertFalse(WelcomeStep.howItWorks.isTour)
        XCTAssertTrue(WelcomeStep.howItWorks.content.features.isEmpty)
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

    func test_persistenceKeys_areUniqueAndRoundTrip() {
        // These names are a storage format: they are what a resume marker is
        // written as, so they must be distinct and readable back.
        let keys = WelcomeStep.allCases.map(\.persistenceKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        for step in WelcomeStep.allCases {
            XCTAssertEqual(WelcomeStep(persistenceKey: step.persistenceKey), step)
        }
    }

    func test_persistenceKeys_areTheCaseNamesNotTheOrdinals() {
        // The whole list, not a sample: these strings are the storage format
        // for the resume marker, so a rename or an ordinal creeping into any
        // one of them should be a deliberate, visible break rather than a
        // silent one that strands stored resume points.
        XCTAssertEqual(
            WelcomeStep.allCases.map(\.persistenceKey),
            ["welcome", "clean", "protect", "tune", "howItWorks", "access", "ready"]
        )
    }

    func test_unknownPersistenceKey_doesNotResolve() {
        XCTAssertNil(WelcomeStep(persistenceKey: "aStepThatWasRemoved"))
        XCTAssertNil(WelcomeStep(persistenceKey: ""))
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

    // MARK: Screenshot slots

    func test_tourSteps_declareAScreenshotSlot() {
        // The slots are what a captured screenshot drops into; only the tour
        // stops show one, since the other steps have bespoke content.
        for step in WelcomeStep.allCases where step.isTour {
            XCTAssertNotNil(step.content.screenshotAssetName, "\(step) has no screenshot slot")
        }
    }

    func test_nonTourSteps_declareNoScreenshotSlot() {
        for step in WelcomeStep.allCases where !step.isTour {
            XCTAssertNil(step.content.screenshotAssetName, "\(step) should not carry a screenshot")
        }
    }

    func test_screenshotSlots_followTheDocumentedNamingConvention() {
        // The convention is what a person capturing screenshots has to type as
        // the asset name, so it is pinned rather than left to memory.
        XCTAssertEqual(WelcomeStep.clean.content.screenshotAssetName, "welcomeShotClean")
        XCTAssertEqual(WelcomeStep.protect.content.screenshotAssetName, "welcomeShotProtect")
        XCTAssertEqual(WelcomeStep.tune.content.screenshotAssetName, "welcomeShotTune")
    }

    func test_everyStepKeepsHeroArtBehindTheScreenshotSlot() {
        // A slot with no asset in the catalog must fall back to something, so
        // the flow never renders an empty hero while screenshots are missing.
        for step in WelcomeStep.allCases {
            let content = step.content
            XCTAssertTrue(
                content.heroAssetName != nil || !content.heroSymbol.isEmpty,
                "\(step) has nothing to fall back to"
            )
        }
    }

    func test_bookendSteps_wearTheSmartScanIdentity() {
        // The flow opens and closes in the app's own violet, so the first-run
        // experience is framed by Smart Scan — where it hands the user off.
        XCTAssertEqual(WelcomeStep.welcome.content.theme, NavigationSection.smartScan.theme)
        XCTAssertEqual(WelcomeStep.ready.content.theme, NavigationSection.smartScan.theme)
    }
}
