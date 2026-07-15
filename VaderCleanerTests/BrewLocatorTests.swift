// BrewLocatorTests.swift
// Verifies DefaultBrewLocator prefers the Apple-silicon prefix, falls back to Intel, and reports absence.

import XCTest
@testable import VaderCleaner

final class BrewLocatorTests: XCTestCase {

    private let appleSilicon = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    private let intel = URL(fileURLWithPath: "/usr/local/bin/brew")

    private func locator(executablePaths: Set<String>) -> DefaultBrewLocator {
        DefaultBrewLocator(
            candidates: [appleSilicon, intel],
            isExecutable: { executablePaths.contains($0) }
        )
    }

    func test_locate_prefersAppleSiliconWhenBothPresent() {
        let found = locator(executablePaths: [appleSilicon.path, intel.path]).locate()
        XCTAssertEqual(found, appleSilicon)
    }

    func test_locate_fallsBackToIntel() {
        let found = locator(executablePaths: [intel.path]).locate()
        XCTAssertEqual(found, intel)
    }

    func test_locate_appleSiliconOnly() {
        let found = locator(executablePaths: [appleSilicon.path]).locate()
        XCTAssertEqual(found, appleSilicon)
    }

    func test_locate_noneInstalledReturnsNil() {
        XCTAssertNil(locator(executablePaths: []).locate())
    }

    func test_locate_presentButNonExecutableReturnsNil() {
        // Path exists as a candidate but the executable check fails for it.
        XCTAssertNil(locator(executablePaths: ["/some/other/path"]).locate())
    }
}
