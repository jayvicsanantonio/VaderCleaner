// UnsupportedAppScannerTests.swift
// Drives DefaultUnsupportedAppScanner with an injected CPU-type provider so classification is exercised without real Mach-O binaries.

import XCTest
@testable import VaderCleaner

final class UnsupportedAppScannerTests: XCTestCase {

    private func makeApp(_ name: String, bundleID: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }

    func test_scan_flagsAppsWithNoRunnableArchitecture() async {
        let legacy = makeApp("Legacy", bundleID: "com.legacy.app")
        let modern = makeApp("Modern", bundleID: "com.modern.app")
        let scanner = DefaultUnsupportedAppScanner { app in
            app.bundleID == "com.legacy.app" ? [7] : [MachOCPUType.arm64]
        }

        let result = await scanner.scan(apps: [legacy, modern])

        XCTAssertEqual(result.map(\.app.bundleID), ["com.legacy.app"])
        XCTAssertEqual(result.first?.reason, .incompatibleArchitecture)
    }

    func test_scan_doesNotFlagAppsWhoseArchitectureCannotBeRead() async {
        let unknown = makeApp("Unknown", bundleID: "com.unknown.app")
        let scanner = DefaultUnsupportedAppScanner { _ in nil }

        let result = await scanner.scan(apps: [unknown])

        XCTAssertTrue(result.isEmpty, "An unreadable executable must never be flagged")
    }

    func test_scan_keepsOnlyUnsupportedAppsAndPreservesOrder() async {
        let a = makeApp("A", bundleID: "a")   // legacy
        let b = makeApp("B", bundleID: "b")   // modern
        let c = makeApp("C", bundleID: "c")   // legacy
        let scanner = DefaultUnsupportedAppScanner { app in
            app.bundleID == "b" ? [MachOCPUType.x86_64] : [7, 18]
        }

        let result = await scanner.scan(apps: [a, b, c])

        XCTAssertEqual(result.map(\.app.bundleID), ["a", "c"])
    }

    func test_scan_emptyInput_returnsEmpty() async {
        let scanner = DefaultUnsupportedAppScanner { _ in [7] }
        let result = await scanner.scan(apps: [])
        XCTAssertTrue(result.isEmpty)
    }
}
