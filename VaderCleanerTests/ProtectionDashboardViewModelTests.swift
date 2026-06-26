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
