// CoreStringTablesTests.swift
// Pins that the core reads its strings from VaderCleanerCore's own resource bundle, so identifier keys and stringsdict plurals resolve with no host app.

import Foundation
import Testing
@testable import VaderCleanerCore

/// Hostless, `Bundle.main` is the test runner and carries no string tables, so
/// every expectation here holds only when the lookup reaches the package's
/// own `en.lproj`. Each singular is spelled out in full: without the
/// stringsdict entry the count still renders, just in the plural ("1 tasks
/// due"), so a key left behind in the app's table fails by name here.
@Suite struct CoreStringTablesTests {

    /// `MemoryPressure.*` are identifier keys rather than English, so they read
    /// as text only when Localizable.strings is found.
    @Test(arguments: [
        (MemoryPressureLevel.nominal, "Normal"),
        (.fair, "Fair"),
        (.critical, "Critical"),
    ])
    func pressureLabelsResolveFromThePackageTable(level: MemoryPressureLevel, label: String) {
        #expect(SystemStatsFormatters.pressureLabel(for: level) == label)
    }

    @Test(arguments: [
        (CareFinding(payload: .threats([MalwareThreat(filePath: URL(fileURLWithPath: "/a"), threatName: "T")])), "1 threat found"),
        (CareFinding(payload: .loginItems([LoginItem(id: "a", name: "Agent", isEnabled: true)])), "1 login item"),
        (CareFinding(payload: .maintenanceDue(taskIDs: ["a"])), "1 task due"),
        (CareFinding(payload: .appUpdates([Self.update])), "1 update available"),
        (CareFinding(payload: .browserPrivacy([BrowserPrivacySummary(browser: .safari, counts: [.cookies: 1])])), "1 item"),
    ])
    func cardMetricsUseThePackageStringsdict(finding: CareFinding, metric: String) {
        #expect(CareFindingCopy.metric(for: finding) == metric)
    }

    @Test func verdictDetailUsesThePackageStringsdict() {
        // One actionable finding, so the detail reaches its count branch.
        let junk = ScannedFile(
            url: URL(fileURLWithPath: "/cache/blob"),
            size: 5_000_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let plan = CarePlan(
            findings: [CareFinding(payload: .junk(ScanResult(items: [junk])))],
            health: nil,
            unitOutcomes: [:],
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
        #expect(CareVerdictEngine.detail(for: plan, readyCount: 1, safeFreeableBytes: 0) == "1 thing worth doing.")
        let bytes = CareFindingCopy.formattedBytes(5_000_000)
        #expect(
            CareVerdictEngine.detail(for: plan, readyCount: 1, safeFreeableBytes: 5_000_000)
                == "1 thing worth doing — \(bytes) can be freed safely."
        )
    }

    private static let update = UpdateInfo(
        appName: "Example",
        bundleID: "com.example.app",
        bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
        installedVersion: "1.0",
        latestVersion: "1.1",
        source: .appStore,
        updateURL: nil
    )
}
