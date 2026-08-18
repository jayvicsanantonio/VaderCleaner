// ProtectionDashboardViewModelTests.swift
// Drives the Protection dashboard coordinator — intro/results gating, starting both child scans, Stop behavior, and Start Over reset — through injected fakes.

import XCTest
@testable import VaderCleaner

@MainActor
final class ProtectionDashboardViewModelTests: XCTestCase {

    private let threat = MalwareThreat(
        filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.bin"),
        threatName: "Eicar-Test-Signature"
    )

    // MARK: - Presentation gating

    func test_scanPresentation_isIntroBeforeScanning() {
        let sut = makeSUT()
        XCTAssertEqual(sut.scanPresentation, .intro)
    }

    func test_beginScan_marksHasScannedAndShowsDashboardImmediately() {
        let sut = makeSUT()
        sut.beginScan()
        // hasScanned flips synchronously, so the dashboard is shown right away
        // — before either scan has had a chance to finish.
        XCTAssertTrue(sut.hasScanned)
        XCTAssertEqual(sut.scanPresentation, .results)
    }

    func test_beginScan_startsBothMalwareAndPrivacyScans() async {
        let sut = makeSUT(
            malwareScan: { _, _ in [] },     // clean
            privacyDetector: { [] }          // no browsers → lands in .preview
        )

        sut.beginScan()
        await waitUntil { sut.malware.phase == .clean }
        await waitUntil { sut.privacy.phase == .preview }

        XCTAssertEqual(sut.malware.phase, .clean)
        XCTAssertEqual(sut.privacy.phase, .preview)
    }

    func test_seededMalwareResult_showsDashboardWithoutScanningHere() {
        // A Smart Scan seed lands the malware flow in a result without going
        // through this coordinator's beginScan; the dashboard should still show.
        let sut = makeSUT()
        sut.malware.seed(threats: [threat], clamAVAvailable: true, scannedAt: Date())

        XCTAssertFalse(sut.hasScanned)
        XCTAssertEqual(sut.scanPresentation, .results)
    }

    // MARK: - Smart Scan pre-warm

    /// After a Smart Scan, the dashboard seeds its malware tile from the scan's
    /// results and kicks off the fast privacy preview so both are ready when the
    /// user opens Protection — without re-running the (already-completed) malware
    /// scan.
    func test_prewarmFromSmartScan_seedsMalwareAndStartsPrivacyPreview() async {
        let sut = makeSUT(privacyDetector: { [] })   // no browsers → lands in .preview

        sut.prewarmFromSmartScan(threats: [threat], clamAVAvailable: true, scannedAt: Date())

        XCTAssertTrue(sut.hasScanned)
        XCTAssertEqual(sut.scanPresentation, .results)
        XCTAssertEqual(sut.malware.phase, .results([threat]))
        await waitUntil { sut.privacy.phase == .preview }
        XCTAssertEqual(sut.privacy.phase, .preview)
    }

    /// A clean Smart Scan (no threats) seeds the malware tile to `.clean`.
    func test_prewarmFromSmartScan_seedsCleanWhenNoThreats() {
        let sut = makeSUT()
        sut.prewarmFromSmartScan(threats: [], clamAVAvailable: true, scannedAt: Date())
        XCTAssertEqual(sut.malware.phase, .clean)
    }

    /// A Smart Scan that never ran the malware unit — Protection switched off in
    /// Smart Care, an unusable engine, or a failed scan — has nothing to seed.
    /// Claiming the section was scanned swapped its intro for a dashboard whose
    /// malware tile read "Scan Stopped" for a scan the user never started.
    func test_prewarmFromSmartScan_withoutAMalwareResult_leavesTheIntroUp() {
        let sut = makeSUT()

        sut.prewarmFromSmartScan(threats: [], clamAVAvailable: false, scannedAt: Date())

        XCTAssertFalse(sut.hasScanned)
        XCTAssertEqual(sut.scanPresentation, .intro, "the section was never scanned")
        XCTAssertEqual(sut.malware.phase, .idle)
    }

    /// And because it never latched, a later Smart Scan — with Protection turned
    /// back on — still seeds. `hasScanned` is one-shot, so setting it on a
    /// pre-warm that seeded nothing would have wasted the only chance.
    func test_prewarmFromSmartScan_seedsOnALaterScan_afterOneWithoutAResult() {
        let sut = makeSUT()
        sut.prewarmFromSmartScan(threats: [], clamAVAvailable: false, scannedAt: Date())

        sut.prewarmFromSmartScan(threats: [threat], clamAVAvailable: true, scannedAt: Date())

        XCTAssertTrue(sut.hasScanned)
        XCTAssertEqual(sut.malware.phase, .results([threat]))
    }

    // MARK: - Tile removal

    /// The tile's Remove sits behind "This permanently deletes the selected
    /// data. This cannot be undone." A failure that leaves the tile in place
    /// with nothing said reads as a broken button, so the reason is captured for
    /// the alert — and the tile stays, since its data is still there.
    func test_clearPrivacyData_reportsTheFailure_andKeepsTheTile() async {
        let sut = makeSUT(
            privacyDetector: { [.safari] },
            privacyClearer: { _, _ in throw PrivacyTileFailure.denied },
            privacyPaths: { _, _ in [URL(fileURLWithPath: "/tmp/safari-data")] }
        )
        // A category is only actionable once the preview found paths for it, so
        // the clear has to run against a real preview to reach the clearer.
        sut.beginScan()
        await waitUntil { sut.privacy.phase == .preview }

        let cleared = await sut.clearPrivacyData(for: .safari)

        XCTAssertFalse(cleared, "a failed clear must not retire the tile")
        XCTAssertNotNil(sut.removalFailureMessage)
    }

    func test_clearPrivacyData_reportsSuccess_andRaisesNoFailure() async {
        let sut = makeSUT(
            privacyDetector: { [.safari] },
            privacyPaths: { _, _ in [URL(fileURLWithPath: "/tmp/safari-data")] }
        )
        sut.beginScan()
        await waitUntil { sut.privacy.phase == .preview }

        let cleared = await sut.clearPrivacyData(for: .safari)

        XCTAssertTrue(cleared)
        XCTAssertNil(sut.removalFailureMessage)
    }

    func test_clearRecentItems_reportsTheFailure() async {
        let sut = makeSUT(recentFilesClearer: { throw PrivacyTileFailure.denied })

        let cleared = await sut.clearRecentItems()

        XCTAssertFalse(cleared)
        XCTAssertNotNil(sut.removalFailureMessage)
    }

    /// A retry after a failure starts from a clean slate, so a stale reason
    /// can't sit behind a later success.
    func test_dismissRemovalFailure_clearsTheMessage() async {
        let sut = makeSUT(recentFilesClearer: { throw PrivacyTileFailure.denied })
        _ = await sut.clearRecentItems()

        sut.dismissRemovalFailure()

        XCTAssertNil(sut.removalFailureMessage)
    }

    // MARK: - Manager privacy pre-warm

    /// Starting a Protection scan also warms the manager's privacy model
    /// (per-browser categories, per-item rows, real counts) so the Protection
    /// Manager opens already populated instead of blank.
    func test_beginScan_prewarmsManagerPrivacyScan() async {
        let sut = makeSUT(managerBrowsers: [.chrome])

        sut.beginScan()

        await waitUntil { sut.protectionPrivacy.phase == .ready }
        XCTAssertEqual(sut.protectionPrivacy.browsers, [.chrome])
    }

    /// The Smart Scan seed warms the manager's privacy model too, so opening the
    /// manager after a Smart Scan is also instant.
    func test_prewarmFromSmartScan_prewarmsManagerPrivacyScan() async {
        let sut = makeSUT(managerBrowsers: [.chrome])

        sut.prewarmFromSmartScan(threats: [], clamAVAvailable: true, scannedAt: Date())

        await waitUntil { sut.protectionPrivacy.phase == .ready }
        XCTAssertEqual(sut.protectionPrivacy.browsers, [.chrome])
    }

    /// If the user already scanned Protection here, a later Smart Scan pre-warm
    /// must not disturb the flow.
    func test_prewarmFromSmartScan_isNoOpWhenAlreadyScanned() {
        let sut = makeSUT()
        sut.beginScan()
        let malwarePhaseBefore = sut.malware.phase

        sut.prewarmFromSmartScan(threats: [threat], clamAVAvailable: true, scannedAt: Date())

        XCTAssertEqual(sut.malware.phase, malwarePhaseBefore,
                       "Pre-warm is gated on hasScanned, so it must not re-seed the malware flow")
    }

    // MARK: - Scan completion (drives the "scan finished" notification)

    /// `isScanComplete` is false before a scan and true only once both the
    /// malware scan and the privacy preview have settled — the signal the
    /// completion notifier keys off (since `scanPresentation` is `.results` the
    /// moment scanning starts).
    func test_isScanComplete_falseBeforeScan_trueWhenBothChildrenSettle() async {
        let sut = makeSUT(
            malwareScan: { _, _ in [] },     // clean
            privacyDetector: { [] }          // no browsers → lands in .preview
        )
        XCTAssertFalse(sut.isScanComplete, "No scan has started yet")

        sut.beginScan()
        await waitUntil { sut.malware.phase == .clean }
        await waitUntil { sut.privacy.phase == .preview }

        XCTAssertTrue(sut.isScanComplete)
    }

    // MARK: - Stop

    func test_stoppingMalware_keepsDashboardVisible() {
        let sut = makeSUT()
        sut.beginScan()

        // The user taps Stop on the malware tile.
        sut.malware.cancel()

        XCTAssertEqual(sut.malware.phase, .idle)
        XCTAssertEqual(sut.scanPresentation, .results,
                       "Stopping the malware scan must not collapse the dashboard")
    }

    // MARK: - Start Over

    func test_startOver_returnsToIntroAndResetsChildren() async {
        let sut = makeSUT(
            malwareScan: { _, _ in [] },
            privacyDetector: { [] }
        )
        sut.beginScan()
        await waitUntil { sut.malware.phase == .clean }
        await waitUntil { sut.privacy.phase == .preview }

        sut.startOver()

        XCTAssertFalse(sut.hasScanned)
        XCTAssertEqual(sut.scanPresentation, .intro)
        XCTAssertEqual(sut.malware.phase, .idle)
        XCTAssertEqual(sut.privacy.phase, .idle)
    }

    // MARK: - Helpers

    private func makeSUT(
        malwareScan: @escaping MalwareViewModel.Scan = { _, _ in [] },
        privacyDetector: @escaping PrivacyViewModel.Detector = { [] },
        managerBrowsers: [Browser] = [],
        privacyClearer: @escaping PrivacyViewModel.Clearer = { _, _ in },
        recentFilesClearer: @escaping PrivacyViewModel.RecentFilesClearer = { },
        privacyPaths: @escaping PrivacyViewModel.PathsResolver = { _, _ in [] }
    ) -> ProtectionDashboardViewModel {
        let malware = MalwareViewModel(
            checkInstalled: { true },
            databaseLastUpdated: { Date() },
            updateDatabase: { _ in },
            scan: malwareScan,
            removeThreats: { _ in [] },
            notify: { _ in },
            shouldNotify: { true }
        )
        let privacy = PrivacyViewModel(
            detector: privacyDetector,
            sizer: { _, _ in 0 },
            pathsFor: privacyPaths,
            clearer: privacyClearer,
            clearRecentFiles: recentFilesClearer
        )
        let protectionPrivacy = ProtectionPrivacyModel(
            detect: { managerBrowsers }, count: { _, _ in 0 }, items: { _, _ in [] }, remove: { _ in }
        )
        return ProtectionDashboardViewModel(malware: malware, privacy: privacy, protectionPrivacy: protectionPrivacy)
    }
}

/// Stand-in for what a real clear throws (a permission denial, a file that
/// won't move), so the tile's failure reporting can be driven without one.
private enum PrivacyTileFailure: Error {
    case denied
}
