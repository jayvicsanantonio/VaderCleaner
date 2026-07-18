// CareFindingTests.swift
// Tests that CareFinding derives item counts, reclaimable bytes, urgency, and actionability correctly from every payload shape, and that identities and domain mappings stay stable.

import XCTest
@testable import VaderCleaner

final class CareFindingTests: XCTestCase {

    // MARK: - Fixtures

    private func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private func appInfo(_ name: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: "com.example.\(name)",
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }

    private func update(_ name: String) -> UpdateInfo {
        UpdateInfo(
            appName: name,
            bundleID: "com.example.\(name)",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .sparkle,
            updateURL: URL(string: "https://example.com")!
        )
    }

    // MARK: - Item counts

    func test_junkFinding_countsItemsAndBytes() {
        let result = ScanResult(items: [
            file("/a", size: 100), file("/b", size: 50, category: .userLogs)
        ])
        let finding = CareFinding(kind: .junkCleanup, payload: .junk(result))
        XCTAssertEqual(finding.itemCount, 2)
        XCTAssertEqual(finding.reclaimableBytes, 150)
    }

    func test_duplicatesFinding_countsOnlyRedundantCopies() {
        let group = DuplicateGroup(files: [
            file("/original", size: 10),
            file("/copy1", size: 10),
            file("/copy2", size: 10)
        ])
        let finding = CareFinding(kind: .duplicates, payload: .duplicates([group]))
        // The kept original is never counted as removable work.
        XCTAssertEqual(finding.itemCount, 2)
        XCTAssertEqual(finding.reclaimableBytes, 20)
    }

    func test_threatsFinding_countsThreats_noBytes() {
        let threats = [
            MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")
        ]
        let finding = CareFinding(kind: .threats, payload: .threats(threats))
        XCTAssertEqual(finding.itemCount, 1)
        XCTAssertEqual(finding.reclaimableBytes, 0)
    }

    func test_largeOldFilesFinding_sumsSizes() {
        let files = [
            file("/big1", size: 500, category: .largeFile),
            file("/old1", size: 300, category: .oldFile)
        ]
        let finding = CareFinding(kind: .largeOldFiles, payload: .largeOldFiles(files))
        XCTAssertEqual(finding.itemCount, 2)
        XCTAssertEqual(finding.reclaimableBytes, 800)
    }

    func test_unusedAppsFinding_sumsBundleSizes() {
        let unused = [
            UnusedApp(app: appInfo("Stale"), lastUsedDate: .distantPast, sizeBytes: 1_000),
            UnusedApp(app: appInfo("Dusty"), lastUsedDate: .distantPast, sizeBytes: 2_000)
        ]
        let finding = CareFinding(kind: .unusedApps, payload: .unusedApps(unused))
        XCTAssertEqual(finding.itemCount, 2)
        XCTAssertEqual(finding.reclaimableBytes, 3_000)
    }

    func test_leftoversFinding_countsGroups_sumsGroupBytes() {
        let groups = [
            LeftoverGroup(
                bundleID: "com.gone.App",
                displayName: "App",
                urls: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
                totalBytes: 400
            )
        ]
        let finding = CareFinding(kind: .appLeftovers, payload: .appLeftovers(groups))
        XCTAssertEqual(finding.itemCount, 1)
        XCTAssertEqual(finding.reclaimableBytes, 400)
    }

    func test_installersFinding_sumsSizes() {
        let installers = [
            InstallationFile(
                url: URL(fileURLWithPath: "/Downloads/app.dmg"),
                name: "app.dmg",
                sizeBytes: 700,
                kind: .diskImage
            )
        ]
        let finding = CareFinding(kind: .installers, payload: .installers(installers))
        XCTAssertEqual(finding.itemCount, 1)
        XCTAssertEqual(finding.reclaimableBytes, 700)
    }

    func test_appUpdatesFinding_countsUpdates_noBytes() {
        let finding = CareFinding(kind: .appUpdates, payload: .appUpdates([update("One"), update("Two")]))
        XCTAssertEqual(finding.itemCount, 2)
        XCTAssertEqual(finding.reclaimableBytes, 0)
    }

    func test_loginItemsFinding_countsItems() {
        let items = [LoginItem(id: "a", name: "Agent", isEnabled: true)]
        let finding = CareFinding(kind: .loginItems, payload: .loginItems(items))
        XCTAssertEqual(finding.itemCount, 1)
        XCTAssertEqual(finding.reclaimableBytes, 0)
    }

    func test_maintenanceFinding_countsDueTasks() {
        let finding = CareFinding(kind: .maintenanceDue, payload: .maintenanceDue(taskIDs: ["flushDNS", "speedUpMail"]))
        XCTAssertEqual(finding.itemCount, 2)
        XCTAssertEqual(finding.reclaimableBytes, 0)
    }

    func test_browserPrivacyFinding_sumsCountsAcrossBrowsers() {
        let summaries = [
            BrowserPrivacySummary(browser: .safari, counts: [.cookies: 10, .browsingHistory: 5]),
            BrowserPrivacySummary(browser: .chrome, counts: [.cookies: 3])
        ]
        let finding = CareFinding(kind: .browserPrivacy, payload: .browserPrivacy(summaries))
        XCTAssertEqual(finding.itemCount, 18)
        XCTAssertEqual(finding.reclaimableBytes, 0)
    }

    func test_lowDiskSpaceFinding_singleItem() {
        let finding = CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(DiskStats(usedBytes: 95, totalBytes: 100)))
        XCTAssertEqual(finding.itemCount, 1)
        XCTAssertEqual(finding.reclaimableBytes, 0)
    }

    // MARK: - Empty detection

    func test_isEmpty_trueWhenPayloadHasNoWork() {
        XCTAssertTrue(CareFinding(kind: .threats, payload: .threats([])).isEmpty)
        XCTAssertTrue(CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: []))).isEmpty)
        XCTAssertFalse(
            CareFinding(kind: .installers, payload: .installers([
                InstallationFile(url: URL(fileURLWithPath: "/x.pkg"), name: "x.pkg", sizeBytes: 1, kind: .package)
            ])).isEmpty
        )
    }

    // MARK: - Urgency

    func test_urgency_threatsAreCritical() {
        let finding = CareFinding(
            kind: .threats,
            payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/x"), threatName: "T")])
        )
        XCTAssertEqual(finding.urgency, .critical)
    }

    func test_urgency_byteFindingsAreSpace() {
        let finding = CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [file("/a", size: 1)])))
        XCTAssertEqual(finding.urgency, .space)
    }

    func test_urgency_advisoryFindingsAreAttention() {
        XCTAssertEqual(CareFinding(kind: .appUpdates, payload: .appUpdates([update("A")])).urgency, .attention)
        XCTAssertEqual(CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(.empty)).urgency, .attention)
        XCTAssertEqual(CareFinding(kind: .maintenanceDue, payload: .maintenanceDue(taskIDs: ["x"])).urgency, .attention)
    }

    // MARK: - Actionability (the safety model's single source of truth)

    func test_actionability_preApprovedKinds() {
        XCTAssertEqual(CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: []))).actionability, .preApproved)
        XCTAssertEqual(CareFinding(kind: .threats, payload: .threats([])).actionability, .preApproved)
        XCTAssertEqual(CareFinding(kind: .duplicates, payload: .duplicates([])).actionability, .preApproved)
        XCTAssertEqual(CareFinding(kind: .appUpdates, payload: .appUpdates([])).actionability, .preApproved)
        XCTAssertEqual(CareFinding(kind: .maintenanceDue, payload: .maintenanceDue(taskIDs: [])).actionability, .preApproved)
    }

    func test_actionability_optInKinds_realUserData() {
        XCTAssertEqual(CareFinding(kind: .largeOldFiles, payload: .largeOldFiles([])).actionability, .optIn)
        XCTAssertEqual(CareFinding(kind: .unusedApps, payload: .unusedApps([])).actionability, .optIn)
        XCTAssertEqual(CareFinding(kind: .appLeftovers, payload: .appLeftovers([])).actionability, .optIn)
        XCTAssertEqual(CareFinding(kind: .installers, payload: .installers([])).actionability, .optIn)
        XCTAssertEqual(CareFinding(kind: .browserPrivacy, payload: .browserPrivacy([])).actionability, .optIn)
    }

    func test_actionability_informationalKinds() {
        XCTAssertEqual(CareFinding(kind: .loginItems, payload: .loginItems([])).actionability, .informational)
        XCTAssertEqual(CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(.empty)).actionability, .informational)
    }

    // MARK: - Identity

    func test_id_isStableKindRawValue() {
        let finding = CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [])))
        XCTAssertEqual(finding.id, "junkCleanup")
    }

    // MARK: - Unit → domain mapping

    func test_everyUnitExceptHealthSnapshot_hasADomain() {
        for unit in CareScanUnit.allCases where unit != .healthSnapshot {
            XCTAssertNotNil(unit.domain, "\(unit) must belong to a settings/checklist domain")
        }
        XCTAssertNil(CareScanUnit.healthSnapshot.domain, "health telemetry is always-on, never user-toggleable")
    }

    func test_domainUnits_roundTrip() {
        for domain in CareDomain.allCases {
            XCTAssertFalse(domain.units.isEmpty, "\(domain) must own at least one scan unit")
            for unit in domain.units {
                XCTAssertEqual(unit.domain, domain)
            }
        }
    }

    func test_domainRawValues_matchLegacyModuleKeys() {
        // Persisted Smart Scan settings used SmartScanModule raw values; the
        // domains that replace them must keep decoding the same strings.
        XCTAssertEqual(CareDomain.systemJunk.rawValue, "systemJunk")
        XCTAssertEqual(CareDomain.myClutter.rawValue, "myClutter")
        XCTAssertEqual(CareDomain.malware.rawValue, "malware")
        XCTAssertEqual(CareDomain.applications.rawValue, "applications")
        XCTAssertEqual(CareDomain.performance.rawValue, "performance")
        XCTAssertEqual(CareDomain.browserPrivacy.rawValue, "browserPrivacy")
    }
}
