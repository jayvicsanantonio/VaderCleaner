// BrowserDetectorTests.swift
// Verifies that DefaultBrowserDetector reports Safari as always present and surfaces installed browsers based on the injected existence checker — without touching the real /Applications directory.

import XCTest
@testable import VaderCleaner

final class BrowserDetectorTests: XCTestCase {

    /// Safari ships with macOS and cannot be uninstalled through normal
    /// channels, so the detector must report it as installed regardless of
    /// what the existence checker says. Suppressing it from the Privacy UI
    /// would surprise users on every Mac.
    func test_safariIsAlwaysReportedInstalled() {
        let detector = DefaultBrowserDetector(existsAt: { _ in false })
        XCTAssertTrue(detector.installedBrowsers().contains(.safari))
    }

    /// Browsers whose `.app` bundle isn't found at any of the known
    /// locations must be filtered out. We don't show a row for a browser
    /// the user doesn't have — clearing nothing leaves the user wondering
    /// why their data wasn't touched.
    func test_missingBrowsersAreFilteredOut() {
        let detector = DefaultBrowserDetector(existsAt: { _ in false })
        let installed = detector.installedBrowsers()
        XCTAssertEqual(installed, [.safari],
                       "Only Safari should be reported when no other apps exist")
    }

    /// When Chrome's `.app` is present, the detector includes it. We assert
    /// against the system-installs path; the per-user `~/Applications` path
    /// is exercised separately below.
    func test_chrome_isDetectedFromSystemApplicationsPath() {
        let detector = DefaultBrowserDetector(existsAt: { url in
            url.path == "/Applications/Google Chrome.app"
        })
        XCTAssertTrue(detector.installedBrowsers().contains(.chrome))
    }

    /// Per-user installs (`~/Applications/...`) are common for power users
    /// and Homebrew Cask without `--no-quarantine`. The detector must check
    /// both system and user `Applications` directories.
    func test_brave_isDetectedFromUserApplicationsPath() {
        let userApps = "/Users/test/Applications/Brave Browser.app"
        let detector = DefaultBrowserDetector(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            existsAt: { url in url.path == userApps }
        )
        XCTAssertTrue(detector.installedBrowsers().contains(.brave))
    }

    /// Multiple installed browsers must all surface in the result —
    /// detection is independent per case, so a Chrome-and-Firefox machine
    /// reports both alongside Safari.
    func test_multipleBrowsers_areAllReported() {
        let installedPaths: Set<String> = [
            "/Applications/Google Chrome.app",
            "/Applications/Firefox.app"
        ]
        let detector = DefaultBrowserDetector(existsAt: { url in
            installedPaths.contains(url.path)
        })

        let installed = Set(detector.installedBrowsers())
        XCTAssertTrue(installed.contains(.safari))
        XCTAssertTrue(installed.contains(.chrome))
        XCTAssertTrue(installed.contains(.firefox))
        XCTAssertFalse(installed.contains(.brave))
        XCTAssertFalse(installed.contains(.edge))
    }

    /// Detection result must preserve `Browser.allCases` order so the
    /// Privacy UI renders a stable sidebar list — Safari first, then
    /// alphabetical-ish per the enum declaration.
    func test_resultOrderMatchesAllCases() {
        let installedPaths: Set<String> = [
            "/Applications/Google Chrome.app",
            "/Applications/Firefox.app",
            "/Applications/Microsoft Edge.app"
        ]
        let detector = DefaultBrowserDetector(existsAt: { url in
            installedPaths.contains(url.path)
        })

        let installed = detector.installedBrowsers()
        XCTAssertEqual(installed, [.safari, .chrome, .firefox, .edge])
    }
}
