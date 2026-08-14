// WelcomeStoreTests.swift
// Tests the persisted "has this Mac seen the first-run flow" flag, including its fresh-install default and reset.

import XCTest
@testable import VaderCleaner

@MainActor
final class WelcomeStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "VaderCleanerTests.Welcome.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // An isolated suite is not isolated from NSArgumentDomain: that domain
        // is in every UserDefaults instance's search list and outranks the
        // persistent one. Running the suite from a scheme that passes
        // `-welcome.hasCompleted NO` (the documented way to replay the flow,
        // and inherited by the Test action whenever
        // `shouldUseLaunchSchemeArgsEnv` is on) would otherwise shadow every
        // write this test makes and fail it for a reason that has nothing to
        // do with the store.
        //
        // Overwriting the domain with an empty one is the move that works.
        // `removeVolatileDomain(forName:)` looks like the obvious call and is
        // silently a no-op here — the volatile domains are re-derived lazily,
        // so the argument domain is back in the search list by the next read.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func test_freshInstall_hasNotCompletedWelcome() {
        let sut = WelcomeStore(defaults: defaults)
        XCTAssertFalse(sut.hasCompletedWelcome)
    }

    func test_markCompleted_persistsAcrossReload() {
        WelcomeStore(defaults: defaults).markCompleted()
        XCTAssertTrue(WelcomeStore(defaults: defaults).hasCompletedWelcome)
    }

    func test_reset_returnsToTheFreshInstallState() {
        let sut = WelcomeStore(defaults: defaults)
        sut.markCompleted()
        sut.markScanHintSeen()
        sut.reset()
        XCTAssertFalse(sut.hasCompletedWelcome)
        XCTAssertFalse(sut.hasSeenScanHint)
        let reloaded = WelcomeStore(defaults: defaults)
        XCTAssertFalse(reloaded.hasCompletedWelcome)
        XCTAssertFalse(reloaded.hasSeenScanHint)
    }

    // MARK: Scan hint

    func test_freshInstall_hasNotSeenTheScanHint() {
        XCTAssertFalse(WelcomeStore(defaults: defaults).hasSeenScanHint)
    }

    func test_markScanHintSeen_persistsAcrossReload() {
        WelcomeStore(defaults: defaults).markScanHintSeen()
        XCTAssertTrue(WelcomeStore(defaults: defaults).hasSeenScanHint)
    }

    func test_scanHintAndCompletion_areTrackedIndependently() {
        let sut = WelcomeStore(defaults: defaults)
        sut.markCompleted()
        XCTAssertFalse(sut.hasSeenScanHint, "Finishing the flow is not the same as being pointed at the disc")
    }
}
