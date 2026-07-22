// WebDevArtifactTests.swift
// Pins the Web Development Junk split: which findings are per-project artifacts rather than shared package-cache files, the row copy each project artifact gets, and the idle-age rule behind the manager's idle-projects pick.

import XCTest
@testable import VaderCleaner

final class WebDevArtifactTests: XCTestCase {

    private let cacheRoots = [
        "/Users/me/.npm",
        "/Users/me/.pnpm-store",
        "/Users/me/Library/Caches/ms-playwright",
    ]

    // MARK: - Classification

    /// A rolled-up artifact folder inside a code directory is a project
    /// artifact: losing it costs that project a reinstall, so it must never be
    /// treated like a shared cache file.
    func test_isProjectArtifact_folderInsideCodeDirectory() {
        XCTAssertTrue(WebDevArtifact.isProjectArtifact(
            URL(fileURLWithPath: "/Users/me/Developer/pixel-prompt/node_modules"),
            cacheRoots: cacheRoots
        ))
        XCTAssertTrue(WebDevArtifact.isProjectArtifact(
            URL(fileURLWithPath: "/Users/me/Developer/uigen/dist"),
            cacheRoots: cacheRoots
        ))
    }

    /// Files inside a package-manager cache root are not project artifacts —
    /// they're shared and re-downloaded on demand.
    func test_isProjectArtifact_falseForPackageCacheFiles() {
        XCTAssertFalse(WebDevArtifact.isProjectArtifact(
            URL(fileURLWithPath: "/Users/me/.npm/_cacache/content-v2/sha512/ab/cd/ef"),
            cacheRoots: cacheRoots
        ))
        XCTAssertFalse(WebDevArtifact.isProjectArtifact(
            URL(fileURLWithPath: "/Users/me/Library/Caches/ms-playwright/chromium-1200/chrome"),
            cacheRoots: cacheRoots
        ))
    }

    /// The cache root itself is a cache, and a sibling whose name merely starts
    /// with a root's name is not — the match is at path-component boundaries.
    func test_isProjectArtifact_rootItselfAndNearMissSibling() {
        XCTAssertFalse(WebDevArtifact.isProjectArtifact(
            URL(fileURLWithPath: "/Users/me/.npm"),
            cacheRoots: cacheRoots
        ))
        XCTAssertTrue(WebDevArtifact.isProjectArtifact(
            URL(fileURLWithPath: "/Users/me/.npmrc-backup/node_modules"),
            cacheRoots: cacheRoots
        ))
    }

    // MARK: - Row copy

    /// The row names the unit that gets deleted *and* the project it belongs
    /// to, so a glance answers "what am I about to remove, and from where".
    func test_rowTitle_namesProjectAndArtifactFolder() {
        XCTAssertEqual(
            WebDevArtifact.rowTitle(for: URL(fileURLWithPath: "/Users/me/Developer/pixel-prompt/node_modules")),
            "pixel-prompt / node_modules"
        )
    }

    /// An artifact sitting directly in the scan root still names its parent,
    /// rather than rendering a bare folder name with no context.
    func test_rowTitle_artifactDirectlyInScanRoot() {
        XCTAssertEqual(
            WebDevArtifact.rowTitle(for: URL(fileURLWithPath: "/Users/me/Developer/node_modules")),
            "Developer / node_modules"
        )
    }

    /// The subtitle carries the containing folder plus how long the artifact
    /// has sat untouched — the two facts behind the keep-or-remove decision.
    func test_rowSubtitle_carriesAgeAndContainingFolder() {
        let file = artifact(
            "/Users/me/Developer/pixel-prompt/node_modules",
            modified: Date(timeIntervalSince1970: 0)
        )

        let subtitle = WebDevArtifact.rowSubtitle(for: file, now: Date(timeIntervalSince1970: 300 * 86_400))

        XCTAssertTrue(subtitle.contains("/Users/me/Developer/pixel-prompt"), subtitle)
        XCTAssertTrue(subtitle.lowercased().contains("month"), subtitle)
    }

    /// A volume that doesn't report timestamps must degrade to the folder
    /// alone, never to an invented or sentinel age.
    func test_rowSubtitle_withoutTimestampsIsFolderOnly() {
        let file = artifact("/Users/me/Developer/pixel-prompt/node_modules", modified: nil)

        XCTAssertEqual(
            WebDevArtifact.rowSubtitle(for: file, now: Date()),
            "/Users/me/Developer/pixel-prompt"
        )
    }

    // MARK: - Idle rule

    /// Past the threshold an artifact counts as idle; inside it, it doesn't.
    func test_isIdle_comparesAgainstThreshold() {
        let now = Date(timeIntervalSince1970: 400 * 86_400)
        let stale = artifact("/p/a/node_modules", modified: now.addingTimeInterval(-120 * 86_400))
        let fresh = artifact("/p/b/node_modules", modified: now.addingTimeInterval(-10 * 86_400))

        XCTAssertTrue(WebDevArtifact.isIdle(stale, now: now))
        XCTAssertFalse(WebDevArtifact.isIdle(fresh, now: now))
    }

    /// Unknown timestamps must not be swept into an idle bulk selection — "no
    /// date" is not evidence of disuse.
    func test_isIdle_falseWhenTimestampsUnknown() {
        XCTAssertFalse(WebDevArtifact.isIdle(artifact("/p/a/node_modules", modified: nil), now: Date()))
    }

    /// Modification time wins when both are present: a scan of the folder can
    /// refresh the access date, which would make every artifact look fresh.
    func test_isIdle_prefersModificationDate() {
        let now = Date(timeIntervalSince1970: 400 * 86_400)
        let file = ScannedFile(
            url: URL(fileURLWithPath: "/p/a/node_modules"),
            size: 10,
            lastAccessDate: now,
            lastModifiedDate: now.addingTimeInterval(-200 * 86_400),
            category: .webDevJunk
        )

        XCTAssertTrue(WebDevArtifact.isIdle(file, now: now))
    }

    // MARK: - Helpers

    private func artifact(_ path: String, modified: Date?) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: 1_000,
            lastAccessDate: nil,
            lastModifiedDate: modified,
            category: .webDevJunk
        )
    }
}
