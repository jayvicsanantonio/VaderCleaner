// UnusedAppScannerTests.swift
// Drives DefaultUnusedAppScanner with injected last-used dates and a fixed "now", covering the threshold boundary, the unknown-date guard, oldest-first ordering, and threshold configuration — fully hermetic.

import XCTest
@testable import VaderCleaner

final class UnusedAppScannerTests: XCTestCase {

    /// Fixed reference "now" so age assertions don't depend on real time.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func makeApp(_ name: String, bundleID: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }

    private func scanner(
        thresholdDays: Int = DefaultUnusedAppScanner.defaultThresholdDays,
        dates: [String: Date?],
        sizes: [String: Int64] = [:]
    ) -> DefaultUnusedAppScanner {
        DefaultUnusedAppScanner(
            thresholdDays: thresholdDays,
            lastUsedDate: { app in dates[app.bundleID] ?? nil },
            bundleSize: { app in sizes[app.bundleID] ?? 0 },
            now: { self.now }
        )
    }

    func test_scan_flagsAppsOlderThanThreshold() async {
        let stale = makeApp("Stale", bundleID: "com.stale.app")
        let fresh = makeApp("Fresh", bundleID: "com.fresh.app")
        let s = scanner(dates: [
            "com.stale.app": now.addingTimeInterval(-90 * day),
            "com.fresh.app": now.addingTimeInterval(-3 * day),
        ])

        let result = await s.scan(apps: [stale, fresh])

        XCTAssertEqual(result.map(\.app.bundleID), ["com.stale.app"])
        XCTAssertEqual(result.first?.lastUsedDate, now.addingTimeInterval(-90 * day))
    }

    func test_scan_populatesSizeBytesFromProvider() async {
        // The dashboard's Unused card reads the total on-disk size off the scan
        // result, so each flagged app must carry its measured size.
        let stale = makeApp("Stale", bundleID: "com.stale.app")
        let s = scanner(
            dates: ["com.stale.app": now.addingTimeInterval(-90 * day)],
            sizes: ["com.stale.app": 5_000_000]
        )

        let result = await s.scan(apps: [stale])

        XCTAssertEqual(result.map(\.sizeBytes), [5_000_000])
    }

    func test_scan_doesNotFlagAppsWithNoKnownLastUsedDate() async {
        let unknown = makeApp("Unknown", bundleID: "com.unknown.app")
        let s = scanner(dates: ["com.unknown.app": Optional<Date>.none])

        let result = await s.scan(apps: [unknown])

        XCTAssertTrue(result.isEmpty, "An app with no usage record must never be flagged")
    }

    func test_scan_thresholdBoundaryIsInclusive() async {
        // Exactly 60 days old → not used within the window → flagged.
        let boundary = makeApp("Boundary", bundleID: "com.boundary.app")
        let s = scanner(dates: ["com.boundary.app": now.addingTimeInterval(-60 * day)])

        let result = await s.scan(apps: [boundary])

        XCTAssertEqual(result.map(\.app.bundleID), ["com.boundary.app"])
    }

    func test_scan_justInsideThreshold_isNotFlagged() async {
        let recent = makeApp("Recent", bundleID: "com.recent.app")
        let s = scanner(dates: ["com.recent.app": now.addingTimeInterval(-59 * day)])

        let result = await s.scan(apps: [recent])

        XCTAssertTrue(result.isEmpty, "An app used within the window must not be flagged")
    }

    func test_scan_ordersOldestFirst() async {
        let a = makeApp("A", bundleID: "a")
        let b = makeApp("B", bundleID: "b")
        let c = makeApp("C", bundleID: "c")
        let s = scanner(dates: [
            "a": now.addingTimeInterval(-70 * day),
            "b": now.addingTimeInterval(-200 * day),
            "c": now.addingTimeInterval(-90 * day),
        ])

        let result = await s.scan(apps: [a, b, c])

        XCTAssertEqual(result.map(\.app.bundleID), ["b", "c", "a"],
                       "Most-stale app must come first")
    }

    func test_scan_honorsCustomThreshold() async {
        let app = makeApp("App", bundleID: "com.app")
        // 10 days old: unused under a 7-day threshold, fine under 60.
        let s7 = scanner(thresholdDays: 7, dates: ["com.app": now.addingTimeInterval(-10 * day)])
        let s60 = scanner(thresholdDays: 60, dates: ["com.app": now.addingTimeInterval(-10 * day)])

        let under7 = await s7.scan(apps: [app])
        let under60 = await s60.scan(apps: [app])

        XCTAssertEqual(under7.map(\.app.bundleID), ["com.app"])
        XCTAssertTrue(under60.isEmpty)
    }

    func test_defaultThreshold_is60Days() {
        XCTAssertEqual(DefaultUnusedAppScanner.defaultThresholdDays, 60)
    }
}
