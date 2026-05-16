// SmartScanViewModelTests.swift
// Drives the SmartScanViewModel state machine — concurrent junk/malware/login orchestration, result aggregation, and the unified clean() delegation — through injected fakes.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelTests: XCTestCase {

    private let threat = MalwareThreat(
        filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.bin"),
        threatName: "Eicar-Test-Signature"
    )

    private let loginItem = LoginItem(id: "com.example.helper", name: "Example Helper", isEnabled: true)

    // MARK: - Initial state

    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
    }

    // MARK: - Scan: orchestration

    func test_scan_runsAllThreeSubScans() async {
        var ranJunk = false
        var ranMalware = false
        var ranLogin = false
        let vm = makeViewModel(
            junkScanner: { ranJunk = true; return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { ranMalware = true; return [] },
            loginItemsLoader: { ranLogin = true; return [] }
        )

        await vm.scan()

        XCTAssertTrue(ranJunk, "Smart Scan must run the System Junk scan")
        XCTAssertTrue(ranMalware, "Smart Scan must run the Malware scan when ClamAV is installed")
        XCTAssertTrue(ranLogin, "Smart Scan must read login items")
    }

    func test_scan_aggregatesResultsFromAllThreeSources() async {
        let junk = makeResult((.userCache, [makeFile(name: "a", size: 100, category: .userCache)]))
        let vm = makeViewModel(
            junkScanner: { junk },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [self.loginItem] }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.junkResult, junk)
        XCTAssertEqual(result.threats, [threat])
        XCTAssertEqual(result.optimizationItems, [loginItem])
        XCTAssertTrue(result.clamAVAvailable)
    }

    func test_scan_reportsTotalJunkBytes() async {
        let junk = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.userLogs, [makeFile(name: "b", size: 250, category: .userLogs)])
        )
        let vm = makeViewModel(junkScanner: { junk })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.totalJunkBytes, 350)
    }

    func test_scan_exposesPerModuleResults() async {
        let junk = makeResult((.trash, [makeFile(name: "t", size: 42, category: .trash)]))
        let second = MalwareThreat(
            filePath: URL(fileURLWithPath: "/Users/me/Library/Caches/x"),
            threatName: "Adware"
        )
        let vm = makeViewModel(
            junkScanner: { junk },
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] },
            loginItemsLoader: { [self.loginItem] }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.junkResult.totalSize, 42)
        XCTAssertEqual(result.threats.count, 2)
        XCTAssertEqual(result.optimizationItems.count, 1)
    }

    func test_scan_whenClamAVNotInstalled_skipsMalwareScanAndMarksUnavailable() async {
        var ranMalware = false
        let vm = makeViewModel(
            junkScanner: { ScanResult(items: []) },
            malwareInstalled: { false },
            malwareScanner: { ranMalware = true; return [self.threat] },
            loginItemsLoader: { [] }
        )

        await vm.scan()

        XCTAssertFalse(ranMalware, "Malware scan must be skipped when ClamAV is not installed")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertFalse(result.clamAVAvailable)
        XCTAssertEqual(result.threats, [])
    }

    func test_scan_junkFailure_movesToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(junkScanner: { throw Boom() })

        await vm.scan()

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    func test_scan_emptyEverywhere_stillLandsInResults() async {
        let vm = makeViewModel(
            junkScanner: { ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { [] },
            loginItemsLoader: { [] }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.totalJunkBytes, 0)
        XCTAssertEqual(result.threats, [])
        XCTAssertEqual(result.optimizationItems, [])
    }

    // MARK: - Clean: delegation

    func test_clean_delegatesToJunkCleanerAndThreatRemover() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        var cleanedFiles: [ScannedFile] = []
        var removedThreats: [MalwareThreat] = []
        var disabledLoginItems: [LoginItem] = []
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [junkFile])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [self.loginItem] },
            junkCleaner: { files in cleanedFiles = files; return 100 },
            threatRemover: { threats in removedThreats = threats; return [] }
        )
        await vm.scan()

        await vm.clean()

        XCTAssertEqual(cleanedFiles, [junkFile], "clean() must hand the scanned junk files to the junk cleaner")
        XCTAssertEqual(removedThreats, [threat], "clean() must hand the detected threats to the threat remover")
        XCTAssertTrue(disabledLoginItems.isEmpty,
                      "clean() must NOT auto-disable login items — Optimization is a Review action, not a cleaner")
    }

    func test_clean_reportsSummary() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [] },
            junkCleaner: { _ in 2_048 },
            threatRemover: { _ in [] }
        )
        await vm.scan()

        await vm.clean()

        XCTAssertEqual(vm.phase, .done(summary: SmartScanSummary(bytesFreed: 2_048, threatsRemoved: 1)))
    }

    func test_clean_partialThreatFailure_reportsRemovedCount() async {
        let second = MalwareThreat(
            filePath: URL(fileURLWithPath: "/Library/Caches/x"),
            threatName: "OSX.Bad"
        )
        let vm = makeViewModel(
            junkScanner: { ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] },
            loginItemsLoader: { [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [second] }   // second could not be removed
        )
        await vm.scan()

        await vm.clean()

        XCTAssertEqual(vm.phase, .done(summary: SmartScanSummary(bytesFreed: 0, threatsRemoved: 1)))
    }

    func test_clean_junkFailure_movesToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) },
            junkCleaner: { _ in throw Boom() }
        )
        await vm.scan()

        await vm.clean()

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    func test_clean_whenNotInResults_isNoop() async {
        var cleaned = false
        let vm = makeViewModel(junkCleaner: { _ in cleaned = true; return 0 })

        await vm.clean()

        XCTAssertFalse(cleaned, "clean() before a scan must be a no-op")
        XCTAssertEqual(vm.phase, .idle)
    }

    // MARK: - Helpers

    private func makeViewModel(
        junkScanner: @escaping SmartScanViewModel.JunkScanner = { ScanResult(items: []) },
        malwareInstalled: @escaping SmartScanViewModel.MalwareInstalled = { true },
        malwareScanner: @escaping SmartScanViewModel.MalwareScanner = { [] },
        loginItemsLoader: @escaping SmartScanViewModel.LoginItemsLoader = { [] },
        junkCleaner: @escaping SmartScanViewModel.JunkCleaner = { _ in 0 },
        threatRemover: @escaping SmartScanViewModel.ThreatRemover = { _ in [] }
    ) -> SmartScanViewModel {
        SmartScanViewModel(
            junkScanner: junkScanner,
            malwareInstalled: malwareInstalled,
            malwareScanner: malwareScanner,
            loginItemsLoader: loginItemsLoader,
            junkCleaner: junkCleaner,
            threatRemover: threatRemover
        )
    }

    private func makeResult(_ groups: (ScanCategory, [ScannedFile])...) -> ScanResult {
        ScanResult(items: groups.flatMap { $0.1 })
    }

    private func makeFile(name: String, size: Int64, category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/ssv-tests/\(category.rawValue)/\(name)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }
}
