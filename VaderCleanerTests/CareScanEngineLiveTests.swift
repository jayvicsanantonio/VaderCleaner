// CareScanEngineLiveTests.swift
// Tests the extractable logic behind the live unit runners: maintenance-due gating (periodic removed in macOS 26), browser privacy summary assembly, and the health snapshot read.

import XCTest
@testable import VaderCleaner

final class CareScanEngineLiveTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VaderCleanerTests.CareScanEngineLive.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Malware lane scope

    @MainActor
    func test_malwareScanScope_matchesTheProtectionQuickScan() {
        // Smart Scan's malware lane and the Protection screen's Quick Scan are
        // the same sweep — that's the promise `live()` makes about every lane.
        // The two drifted apart once already when Quick was redefined, so the
        // lane resolves its scope through the same function rather than
        // keeping a second path list of its own.
        let scope = CareScanEngine.UnitRunners.malwareScanScope(excludeICloud: false)
        let quick = MalwareViewModel.scanScope(for: .quick, excludeICloud: false)

        XCTAssertEqual(scope.paths.map(\.path), quick.paths.map(\.path))
        XCTAssertEqual(scope.excludedDirectories, quick.excludedDirectories)
    }

    @MainActor
    func test_malwareScanScope_checksPersistenceVectorsNotTheUserFolders() {
        // The behaviour the alignment is for: a care-plan sweep that stays
        // fast. Pointing the lane back at the user folders would put Smart
        // Scan's slowest lane back on everything the user ever downloaded.
        let scope = CareScanEngine.UnitRunners.malwareScanScope(excludeICloud: false)
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertFalse(
            scope.paths.contains { ["Downloads", "Desktop", "Documents"].contains($0.lastPathComponent) },
            "the malware lane must not walk the user folders"
        )
        XCTAssertFalse(scope.paths.contains(home), "the malware lane must not walk the whole home")
        XCTAssertTrue(
            MalwareViewModel.systemPersistenceVectorPaths()
                .map(\.path)
                .allSatisfy(scope.paths.map(\.path).contains),
            "the malware lane should check the system launch directories"
        )
    }

    // MARK: - Maintenance due

    func test_dueMaintenance_freshLog_allCocktailTasksDue() {
        let ids = CareScanEngine.UnitRunners.dueMaintenanceTaskIDs(
            runLog: MaintenanceRunLog(defaults: defaults),
            maintenanceScriptsAvailable: true
        )
        XCTAssertEqual(ids, MaintenanceTask.maintenanceCocktailKinds.map(\.rawValue))
    }

    func test_dueMaintenance_withoutPeriodic_excludesMaintenanceScripts() {
        let ids = CareScanEngine.UnitRunners.dueMaintenanceTaskIDs(
            runLog: MaintenanceRunLog(defaults: defaults),
            maintenanceScriptsAvailable: false
        )
        XCTAssertFalse(ids.contains(MaintenanceTask.Kind.runMaintenanceScripts.rawValue))
        XCTAssertTrue(ids.contains(MaintenanceTask.Kind.flushDNS.rawValue))
    }

    func test_dueMaintenance_recentlyRunTask_isNotDue() {
        let log = MaintenanceRunLog(defaults: defaults)
        log.record(MaintenanceTask.Kind.flushDNS.rawValue)
        let ids = CareScanEngine.UnitRunners.dueMaintenanceTaskIDs(
            runLog: log,
            maintenanceScriptsAvailable: true
        )
        XCTAssertFalse(ids.contains(MaintenanceTask.Kind.flushDNS.rawValue))
    }

    // MARK: - Browser privacy summaries

    func test_browserPrivacy_buildsPerBrowserCounts_droppingZeroCategoriesAndEmptyBrowsers() async {
        let summaries = await CareScanEngine.UnitRunners.browserPrivacySummaries(
            browsers: [.safari, .chrome],
            count: { category, browser in
                guard browser == .safari else { return 0 }
                switch category {
                case .cookies: return 12
                case .browsingHistory: return 4
                default: return 0
                }
            }
        )
        XCTAssertEqual(summaries.count, 1, "browsers with nothing counted should not appear")
        XCTAssertEqual(summaries.first?.browser, .safari)
        XCTAssertEqual(summaries.first?.counts, [.cookies: 12, .browsingHistory: 4])
        XCTAssertEqual(summaries.first?.totalItems, 16)
    }

    // MARK: - Health snapshot

    @MainActor
    func test_healthSnapshot_readsCheapStatsFromTheAppScopedService() async {
        let service = SystemStatsService(autostart: false)
        service.refresh()
        let runners = CareScanEngine.UnitRunners.live(
            exclusions: ExclusionsStore(defaults: defaults),
            statsService: service
        )
        let snapshot = await runners.healthSnapshot()
        XCTAssertEqual(snapshot?.disk, service.diskSpace)
        XCTAssertEqual(snapshot?.memoryPressure, service.ramUsage.pressureLevel)
        XCTAssertEqual(snapshot?.smart, service.diskSMARTStatus)
        XCTAssertEqual(snapshot?.battery, service.batteryAvailability)
    }
}
