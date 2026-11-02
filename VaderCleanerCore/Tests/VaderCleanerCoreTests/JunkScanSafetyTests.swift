// JunkScanSafetyTests.swift
// Pins what a junk scan may offer for removal: project artifacts only where a project exists, nothing inside repositories or virtualenvs, whole Trash items and iOS backups as single units, and exclusions honoured inside rolled-up folders.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite("Junk scan safety")
struct JunkScanSafetyTests {

    private func touch(_ url: URL, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func withTempRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }
        return try await body(root)
    }

    // MARK: - Project artifacts

    @Test("Paths inside a repository's metadata are never offered")
    func skipsGitMetadata() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("app/.git/refs/heads/build/release-1"))
            try touch(root.appendingPathComponent("app/.git/refs/remotes/origin/dist/hotfix"))
            try touch(root.appendingPathComponent("app/package.json"))

            let found = await DeveloperProjectScanner(roots: [root]).scan()

            #expect(found.isEmpty)
        }
    }

    @Test("Folders inside a virtualenv are never offered")
    func skipsVirtualenvContents() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("app/.venv/lib/python3.12/site-packages/foo/setup.py"))
            try touch(root.appendingPathComponent("app/.venv/lib/python3.12/site-packages/foo/build/module.py"))
            try touch(root.appendingPathComponent("app/venv/lib/python3.12/site-packages/bar/setup.py"))
            try touch(root.appendingPathComponent("app/venv/lib/python3.12/site-packages/bar/build/module.py"))

            let found = await DeveloperProjectScanner(roots: [root]).scan()

            #expect(found.isEmpty)
        }
    }

    @Test("A folder named build, dist, or target with no project beside it is not junk")
    func ambiguousNamesNeedAManifest() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("Taxes/target/2025-return.pdf"))
            try touch(root.appendingPathComponent("House/build/permit.pdf"))
            try touch(root.appendingPathComponent("Trips/dist/itinerary.pdf"))

            let found = await DeveloperProjectScanner(roots: [root]).scan()

            #expect(found.isEmpty)
        }
    }

    @Test(
        "An ambiguous folder name counts beside its toolchain's manifest",
        arguments: [
            ("build", "package.json"), ("build", "build.gradle"), ("build", "CMakeLists.txt"),
            ("dist", "package.json"), ("dist", "pyproject.toml"), ("dist", "setup.py"),
            ("target", "Cargo.toml"), ("target", "pom.xml"),
        ]
    )
    func ambiguousNameWithManifestIsOffered(folder: String, manifest: String) async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("app/\(manifest)"))
            try touch(root.appendingPathComponent("app/\(folder)/output.bin"))

            let found = await DeveloperProjectScanner(roots: [root]).scan()

            #expect(found.map(\.url.lastPathComponent) == [folder])
        }
    }

    @Test("Another toolchain's manifest doesn't vouch for a folder name")
    func manifestMustMatchTheFolderName() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("app/package.json"))
            try touch(root.appendingPathComponent("app/target/data.csv"))

            let found = await DeveloperProjectScanner(roots: [root]).scan()

            #expect(found.isEmpty)
        }
    }

    @Test("Names only a toolchain creates need no manifest")
    func unambiguousNamesNeedNoManifest() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("app/node_modules/x.js"))
            try touch(root.appendingPathComponent("tool/__pycache__/x.pyc"))

            let found = await DeveloperProjectScanner(roots: [root]).scan()

            #expect(Set(found.map(\.url.lastPathComponent)) == ["node_modules", "__pycache__"])
        }
    }

    @Test("A scan rooted at the home folder stays out of Library, hidden folders, and app bundles")
    func homeRootSkipsNonProjectTrees() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("Library/Caches/tool/node_modules/x.js"))
            try touch(root.appendingPathComponent(".Trash/old-project/node_modules/x.js"))
            try touch(root.appendingPathComponent(".npm/_cacache/node_modules/x.js"))
            try touch(root.appendingPathComponent("Editor.app/Contents/Resources/app/node_modules/x.js"))
            try touch(root.appendingPathComponent("Developer/app/node_modules/x.js"))

            let found = await DeveloperProjectScanner(roots: [root]).scan().map(\.url.path)

            #expect(found.count == 1)
            #expect(found.first?.hasSuffix("/Developer/app/node_modules") == true)
        }
    }

    @Test("Recent work deep inside an artifact keeps it from counting as idle")
    func idleLooksInsideTheFolder() async throws {
        try await withTempRoot { root in
            let artifact = root.appendingPathComponent("app/dist", isDirectory: true)
            try touch(root.appendingPathComponent("app/package.json"))
            let inner = artifact.appendingPathComponent("bundle/main.js")
            try touch(inner)
            let old = Date().addingTimeInterval(-200 * 86_400)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: artifact.path)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: inner.path)

            let found = await DeveloperProjectScanner(roots: [root]).scan()
            let file = try #require(found.first)

            #expect(!WebDevArtifact.isIdle(file))
        }
    }

    @Test("An artifact with nothing recent inside it still counts as idle")
    func idleStillFindsOldArtifacts() async throws {
        try await withTempRoot { root in
            let artifact = root.appendingPathComponent("app/node_modules", isDirectory: true)
            let inner = artifact.appendingPathComponent("x.js")
            try touch(inner)
            let old = Date().addingTimeInterval(-200 * 86_400)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: inner.path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: artifact.path)

            let found = await DeveloperProjectScanner(roots: [root]).scan()
            let file = try #require(found.first)

            #expect(WebDevArtifact.isIdle(file))
        }
    }

    // MARK: - Exclusions

    @Test("An exclusion inside a rolled-up folder keeps the folder from being offered")
    func exclusionInsideRollup() {
        let rollup = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Developer/app/node_modules"),
            size: 500, lastAccessDate: nil, lastModifiedDate: nil, category: .webDevJunk
        )
        let kept = SystemJunkScanner.excluding(
            [rollup],
            paths: [URL(fileURLWithPath: "/Users/me/Developer/app/node_modules/keep-me")]
        )
        #expect(kept.isEmpty)
    }

    // MARK: - Whole-item roots

    @Test("Each top-level Trash item is one removable unit, symlinks and empty folders included")
    func trashItemsRollUp() async throws {
        try await withTempRoot { root in
            try touch(root.appendingPathComponent("Project/src/main.swift"), bytes: 30)
            try touch(root.appendingPathComponent("Project/README"), bytes: 12)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("EmptyFolder"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias-link"),
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )
            try touch(root.appendingPathComponent("loose.dmg"), bytes: 5)

            let files = try await FileScanner().scan(
                roots: [ScanRoot(url: root, category: .trash, packagesAsFiles: true, rollsUpTopLevelItems: true)],
                excluding: []
            )

            let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.url.lastPathComponent, $0.size) })
            #expect(sizes == ["Project": 42, "EmptyFolder": 0, "alias-link": 0, "loose.dmg": 5])
        }
    }

    @Test("An excluded file inside a rolled-up item keeps that item from rolling up")
    func exclusionInsideTopLevelItem() async throws {
        try await withTempRoot { root in
            let keep = root.appendingPathComponent("Project/keep.txt")
            try touch(keep)
            try touch(root.appendingPathComponent("Project/other.txt"))

            let files = try await FileScanner().scan(
                roots: [ScanRoot(url: root, category: .trash, rollsUpTopLevelItems: true)],
                excluding: [keep]
            )

            #expect(files.map(\.url.lastPathComponent) == ["other.txt"])
        }
    }

    @Test("Trash roots and iOS backups roll up; caches keep their per-file listing")
    func providerOptsRootsIn() throws {
        let home = URL(fileURLWithPath: "/Users/nobody-here", isDirectory: true)
        let roots = DefaultSystemPathProvider(
            homeDirectory: home,
            languageFileLocator: LanguageFileLocator(scanRoots: [], activeLanguageCodes: []),
            hasFullDiskAccess: { false }
        ).roots()

        let trash = try #require(roots.first { $0.category == .trash })
        let backups = try #require(roots.first { $0.category == .iosBackups })
        let caches = try #require(roots.first { $0.category == .userCache })
        #expect(trash.rollsUpTopLevelItems)
        #expect(backups.rollsUpTopLevelItems)
        #expect(!caches.rollsUpTopLevelItems)
    }

    // MARK: - Mail attachments

    @Test("Mail's container folder is scanned only with Full Disk Access")
    func mailContainerNeedsFullDiskAccess() {
        let home = URL(fileURLWithPath: "/Users/nobody-here", isDirectory: true)
        let locator = LanguageFileLocator(scanRoots: [], activeLanguageCodes: [])
        let container = home.path + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

        let withAccess = DefaultSystemPathProvider(homeDirectory: home, languageFileLocator: locator, hasFullDiskAccess: { true }).roots()
        let withoutAccess = DefaultSystemPathProvider(homeDirectory: home, languageFileLocator: locator, hasFullDiskAccess: { false }).roots()

        let mailRoot = withAccess.first { $0.url.path == container }
        #expect(mailRoot?.category == .mailAttachments)
        #expect(mailRoot?.packagesAsFiles == true)
        #expect(!withoutAccess.contains { $0.url.path == container })
        #expect(withoutAccess.contains { $0.category == .mailAttachments })
    }

    // MARK: - Language codes

    @Test(
        "A language's alternate code counts as that language",
        arguments: [("no", "nb"), ("iw", "he"), ("in", "id"), ("ji", "yi"), ("tl", "fil")]
    )
    func languageAliases(alias: String, preferred: String) throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let lproj = root.appendingPathComponent("Foo.app/Contents/Resources/\(alias).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)

        let found = LanguageFileLocator(scanRoots: [root], activeLanguageCodes: [preferred]).locate()

        #expect(found.isEmpty)
    }

    @Test("Non-language pseudo codes are never language junk", arguments: ["mul", "und", "zxx"])
    func pseudoLocales(code: String) {
        #expect(LanguageFileLocator.languageCode(fromLocaleName: code) == nil)
    }
}
