// DefaultSystemPathProviderTests.swift
// Pins the default-wiring decisions in DefaultSystemPathProvider — English fallback preservation and the language scan roots — that govern what a real System Junk scan produces on a user's machine.

import XCTest
@testable import VaderCleaner

/// `DefaultSystemPathProvider`'s `roots()` walks the real macOS filesystem
/// and is therefore not driven directly here — the test seam for that is
/// `StubSystemPathProvider` in `SystemJunkScannerTests`. What this file
/// covers is the *defaults*: how `DefaultSystemPathProvider` builds its
/// language-file locator. Both decisions (always-active English, the
/// `~/Applications` root) were called out by Codex review on PR #28.
final class DefaultSystemPathProviderTests: XCTestCase {

    // MARK: - English fallback preservation

    /// English must always be in the active set even if the user's
    /// preferred languages don't include it. macOS bundles fall back to
    /// `CFBundleDevelopmentRegion` (typically `en`) for strings missing in
    /// the user's locale, so removing `en.lproj` or `English.lproj` for a
    /// non-English user can leave apps with blank UI text.
    func test_activePreferredLanguageCodes_alwaysIncludesEnglish() {
        let codes = DefaultSystemPathProvider.activePreferredLanguageCodes()

        XCTAssertTrue(
            codes.contains("en"),
            "English fallback must always be preserved regardless of Locale.preferredLanguages"
        )
    }

    /// Whatever the user's actual preferred languages are at test time,
    /// they must still be honoured — the always-active English must be
    /// additive, not a replacement.
    func test_activePreferredLanguageCodes_includesUserPreferredLanguages() {
        let codes = DefaultSystemPathProvider.activePreferredLanguageCodes()

        let expected = Set(
            Locale.preferredLanguages.compactMap { tag in
                LanguageFileLocator.languageCode(fromLocaleName: tag)
            }
        )
        for code in expected {
            XCTAssertTrue(
                codes.contains(code),
                "Preferred language '\(code)' must remain active"
            )
        }
    }

    // MARK: - Language scan roots

    /// `~/Applications` must be in the default scan roots so per-user app
    /// installs (apps the user dropped under their home directory rather
    /// than `/Applications`) get walked for non-active `.lproj` files.
    /// Without it the entire language-files category for those bundles
    /// went unreported.
    func test_defaultLanguageScanRoots_includesUserApplications() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let roots = DefaultSystemPathProvider.defaultLanguageScanRoots(homeDirectory: home)

        let expected = home.appendingPathComponent("Applications", isDirectory: true)
        XCTAssertTrue(
            roots.contains(expected),
            "Default language roots must include ~/Applications for per-user installs"
        )
    }

    /// System-wide installs and the third-party resource trees must still
    /// be present — adding `~/Applications` is additive, not a replacement.
    func test_defaultLanguageScanRoots_includesSystemWideRoots() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let roots = DefaultSystemPathProvider.defaultLanguageScanRoots(homeDirectory: home)

        XCTAssertTrue(roots.contains(URL(fileURLWithPath: "/Applications", isDirectory: true)))
        XCTAssertTrue(roots.contains(URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)))
        XCTAssertTrue(roots.contains(URL(fileURLWithPath: "/Library/Frameworks", isDirectory: true)))
    }

    /// `/System/Library` must NOT appear — files there live on the
    /// read-only Signed System Volume and reporting them as junk would
    /// mislead the user since they can never be deleted. Pinning this so
    /// nobody re-adds it absent-mindedly.
    func test_defaultLanguageScanRoots_excludesSystemLibrary() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let roots = DefaultSystemPathProvider.defaultLanguageScanRoots(homeDirectory: home)

        XCTAssertFalse(
            roots.contains(URL(fileURLWithPath: "/System/Library", isDirectory: true)),
            "Read-only system volume must stay out of the language-file scan roots"
        )
    }

    // MARK: - Xcode junk roots

    /// Xcode's reclaimable developer junk lives under `~/Library/Developer`.
    /// All of it must be rooted there (user-domain, in-process deletable) so a
    /// Cleanup scan never reaches for a system path that would need the helper.
    func test_xcodeJunkRoots_areUnderUserDeveloperDirectory() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let developer = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)

        let roots = DefaultSystemPathProvider.xcodeJunkRoots(homeDirectory: home)

        XCTAssertFalse(roots.isEmpty, "Expected at least one Xcode junk root")
        for root in roots {
            XCTAssertTrue(
                root.path.hasPrefix(developer.path + "/"),
                "Xcode junk root \(root.path) must live under ~/Library/Developer"
            )
        }
    }

    /// Derived data and archives are the two heaviest Xcode buckets and must
    /// always be covered.
    func test_xcodeJunkRoots_includeDerivedDataAndArchives() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let xcode = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)

        let roots = DefaultSystemPathProvider.xcodeJunkRoots(homeDirectory: home)

        XCTAssertTrue(roots.contains(xcode.appendingPathComponent("DerivedData", isDirectory: true)))
        XCTAssertTrue(roots.contains(xcode.appendingPathComponent("Archives", isDirectory: true)))
    }

    // MARK: - Document Versions store

    /// The Document Versions store path is shared with the privileged helper
    /// (the only thing that can enumerate it) — pin it so the two ends can't
    /// drift apart. It is NOT an in-process FileScanner root, since the store is
    /// root-owned and unreadable by the app directly.
    func test_documentVersionsStorePath_isTheDataVolumeRevisionsStore() {
        XCTAssertEqual(
            kDocumentVersionsStorePath,
            "/System/Volumes/Data/.DocumentRevisions-V100"
        )
    }
}
