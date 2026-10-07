// WelcomeStoreTests.swift
// Tests the persisted "has this Mac seen the first-run flow" flag, including its fresh-install default and reset.

import Foundation
import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

@MainActor
@Suite(.serialized)
final class WelcomeStoreTests {

    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "VaderCleanerTests.Welcome.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // An isolated suite is not isolated from NSArgumentDomain: that domain
        // is in every UserDefaults instance's search list and outranks the
        // persistent one. Running the suite from a scheme that passes
        // `-welcome.hasCompleted NO` (the documented way to replay the flow,
        // and inherited by the Test action whenever
        // `shouldUseLaunchSchemeArgsEnv` is on) would otherwise shadow every
        // write this test makes and fail it for a reason that has nothing to
        // do with the store. This suite runs `.serialized` because it mutates
        // that process-wide argument domain.
        //
        // Overwriting the domain with an empty one is the move that works.
        // `removeVolatileDomain(forName:)` looks like the obvious call and is
        // silently a no-op here — the volatile domains are re-derived lazily,
        // so the argument domain is back in the search list by the next read.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func freshInstall_hasNotCompletedWelcome() {
        let sut = WelcomeStore(defaults: defaults)
        #expect(!sut.hasCompletedWelcome)
    }

    @Test
    func markCompleted_persistsAcrossReload() {
        WelcomeStore(defaults: defaults).markCompleted()
        #expect(WelcomeStore(defaults: defaults).hasCompletedWelcome)
    }

    @Test
    func reset_returnsToTheFreshInstallState() {
        let sut = WelcomeStore(defaults: defaults)
        sut.markCompleted()
        sut.markScanHintSeen()
        sut.recordStep(.access)
        sut.reset()
        #expect(!sut.hasCompletedWelcome)
        #expect(!sut.hasSeenScanHint)
        #expect(sut.resumeStep == nil)
        let reloaded = WelcomeStore(defaults: defaults)
        #expect(!reloaded.hasCompletedWelcome)
        #expect(!reloaded.hasSeenScanHint)
    }

    // MARK: Resume point

    @Test
    func freshInstall_hasNoResumePoint() {
        #expect(WelcomeStore(defaults: defaults).resumeStep == nil)
    }

    @Test
    func recordStep_persistsAcrossReload() {
        // Granting Full Disk Access makes macOS quit the app, so the flow's
        // place has to outlive the process that was showing it.
        WelcomeStore(defaults: defaults).recordStep(.access)
        #expect(WelcomeStore(defaults: defaults).resumeStep == .access)
    }

    @Test
    func resumeStep_ignoresANameThatIsNoLongerAStep() {
        // A build that removes or renames a step must not resume into a case
        // that no longer exists.
        defaults.set("aStepThatWasRemoved", forKey: "welcome.resumeStep")
        #expect(WelcomeStore(defaults: defaults).resumeStep == nil)
    }

    @Test
    func resumeStep_ignoresAStoredValueOfTheWrongType() {
        // The marker used to be written as an ordinal. Anything that isn't a
        // recognised name — including a leftover number — starts over.
        defaults.set(5, forKey: "welcome.resumeStep")
        #expect(WelcomeStore(defaults: defaults).resumeStep == nil)
    }

    @Test
    func resumeStep_isStoredByNameSoReorderingCannotRepointIt() {
        // Presentation order lives in the raw values, so persisting those
        // would make inserting a step silently move everyone's resume marker.
        WelcomeStore(defaults: defaults).recordStep(.access)
        #expect(defaults.string(forKey: "welcome.resumeStep") == "access")
    }

    @Test
    func markCompleted_clearsTheResumePoint() {
        let sut = WelcomeStore(defaults: defaults)
        sut.recordStep(.access)
        sut.markCompleted()
        #expect(sut.resumeStep == nil)
        #expect(WelcomeStore(defaults: defaults).resumeStep == nil)
    }

    // MARK: Scan hint

    @Test
    func freshInstall_hasNotSeenTheScanHint() {
        #expect(!WelcomeStore(defaults: defaults).hasSeenScanHint)
    }

    @Test
    func markScanHintSeen_persistsAcrossReload() {
        WelcomeStore(defaults: defaults).markScanHintSeen()
        #expect(WelcomeStore(defaults: defaults).hasSeenScanHint)
    }

    @Test
    func scanHintAndCompletion_areTrackedIndependently() {
        let sut = WelcomeStore(defaults: defaults)
        sut.markCompleted()
        #expect(!sut.hasSeenScanHint, "Finishing the flow is not the same as being pointed at the disc")
    }
}
