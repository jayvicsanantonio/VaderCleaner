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
        privacyDetector: @escaping PrivacyViewModel.Detector = { [] }
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
            pathsFor: { _, _ in [] },
            clearer: { _, _ in },
            clearRecentFiles: { }
        )
        let protectionPrivacy = ProtectionPrivacyModel(
            detect: { [] }, count: { _, _ in 0 }, items: { _, _ in [] }, remove: { _ in }
        )
        return ProtectionDashboardViewModel(malware: malware, privacy: privacy, protectionPrivacy: protectionPrivacy)
    }
}
