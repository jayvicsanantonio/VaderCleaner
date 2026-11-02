// ClutterCandidateFilterTests.swift
// Pins which files the duplicate and similar-image scans may offer for removal, and which identical copy the duplicate scan keeps.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VaderCleanerCore

@Suite struct ClutterCandidateFilterTests {

    private func makeRoot() throws -> URL {
        try TestHelpers.createTempDirectory()
    }

    @discardableResult
    private func write(_ relativePath: String, _ contents: String = "same bytes", in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func isOffered(roots: [URL], _ url: URL) -> Bool {
        var filter = ClutterCandidateFilter(roots: roots)
        return filter.isOffered(url)
    }

    // MARK: - The filter

    @Test func offersOrdinaryFiles() throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let url = try write("Taxes/2024/return.pdf", in: root)
        #expect(isOffered(roots: [root], url))
    }

    @Test func holdsBackHiddenFilesAndHiddenFolders() throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        #expect(!isOffered(roots: [root], try write(".DS_Store", in: root)))
        #expect(!isOffered(roots: [root], try write("notes/.cache/data.bin", in: root)))
    }

    @Test(arguments: ["node_modules", "bower_components", "__pycache__", "site-packages", "Pods", "DerivedData", "venv"])
    func holdsBackDependencyAndBuildTrees(_ folder: String) throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        #expect(!isOffered(roots: [root], try write("app/\(folder)/pkg/LICENSE", in: root)))
    }

    /// A tracked file looks like any other, but Trashing it damages the checkout
    /// — two clones of one repo would otherwise read as thousands of duplicates.
    @Test(arguments: [".git", ".hg", ".svn"])
    func holdsBackEverythingInsideACheckout(_ marker: String) throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/\(marker)"), withIntermediateDirectories: true)
        #expect(!isOffered(roots: [root], try write("repo/Sources/deep/main.swift", in: root)))
        #expect(isOffered(roots: [root], try write("elsewhere/main.swift", in: root)))
    }

    /// A linked worktree's `.git` is a file rather than a folder.
    @Test func recognisesAWorktreeWhoseMarkerIsAFile() throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        try write("worktree/.git", "gitdir: /elsewhere", in: root)
        #expect(!isOffered(roots: [root], try write("worktree/main.swift", in: root)))
    }

    /// Picking a repo itself as the scan folder doesn't make its files safe.
    @Test func aCheckoutAtTheRootIsStillACheckout() throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(!isOffered(roots: [root], try write("main.swift", in: root)))
    }

    /// Only what sits below the root counts. A home directory that is itself a
    /// dotfiles repo must not silently hide all of `~/Documents`.
    @Test func ignoresACheckoutAboveTheRoot() throws {
        let home = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let documents = home.appendingPathComponent("Documents")
        #expect(isOffered(roots: [documents], try write("Documents/report.pdf", in: home)))
    }

    /// A scan root under a hidden folder was chosen deliberately, so its own
    /// location doesn't count against the files inside it.
    @Test func aHiddenRootStillOffersItsFiles() throws {
        let base = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(base) }
        let root = base.appendingPathComponent(".stash/photos")
        #expect(isOffered(roots: [root], try write(".stash/photos/a.pdf", in: base)))
    }

    /// The walker reports `/var/...` roots as `/private/var/...`, so a root must
    /// match in either spelling or the walk up would run past it.
    @Test func matchesARootAcrossThePrivateFirmlinkSpelling() {
        let parent = "/private/var/folders/x/.hidden/root"
        #expect(isOffered(roots: [URL(fileURLWithPath: "/var/folders/x/.hidden/root")], URL(fileURLWithPath: parent + "/a.pdf")))
    }

    // MARK: - Duplicate scan

    @Test func duplicateScanOffersNothingFromInsideProjects() async throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        try write(".DS_Store", in: root)
        try write("a/.DS_Store", in: root)
        try write("proj/node_modules/x/LICENSE", in: root)
        try write("proj/node_modules/y/LICENSE", in: root)
        try write("one/.git/objects/ab/cd", in: root)
        try write("two/.git/objects/ab/cd", in: root)

        let groups = try await DuplicateScanner(roots: [root]).scan(excluding: [])

        #expect(groups.isEmpty)
    }

    @Test func aProjectFileNeverPairsWithAnOrdinaryCopy() async throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        try write("Documents/LICENSE", in: root)
        try write("proj/node_modules/x/LICENSE", in: root)

        let groups = try await DuplicateScanner(roots: [root]).scan(excluding: [])

        #expect(groups.isEmpty, "Only one offerable copy is left, so nothing is redundant")
    }

    // MARK: - Which copy is kept

    @Test func keepsTheOriginalNameOverItsCopyNames() async throws {
        for copyName in ["report copy.pdf", "report copy 2.pdf", "report 2.pdf", "report (1).pdf", "report-1.pdf"] {
            let root = try makeRoot()
            defer { TestHelpers.tearDownTempDirectory(root) }
            try write("report.pdf", in: root)
            try write(copyName, in: root)

            let groups = try await DuplicateScanner(roots: [root]).scan(excluding: [])

            let kept = try #require(groups.first?.original.url.lastPathComponent)
            #expect(kept == "report.pdf", "kept \(kept) over report.pdf, against \(copyName)")
        }
    }

    /// A filed copy is the one worth keeping: Downloads is the folder the same
    /// section invites the user to clear out next.
    @Test func keepsAFiledCopyOverTheDownloadsCopyEvenWhenDeeper() async throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let downloads = root.appendingPathComponent("Downloads")
        try write("Downloads/return.pdf", in: root)
        try write("Documents/Taxes/2024/return.pdf", in: root)

        let scanner = DuplicateScanner(roots: [root], downloadsDirectory: downloads)
        let groups = try await scanner.scan(excluding: [])

        let kept = try #require(groups.first?.original.url.path)
        #expect(kept.hasSuffix("Documents/Taxes/2024/return.pdf"))
    }

    @Test func filedLocationOutranksACleanName() async throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let downloads = root.appendingPathComponent("Downloads")
        try write("Downloads/return.pdf", in: root)
        try write("Documents/return copy.pdf", in: root)

        let scanner = DuplicateScanner(roots: [root], downloadsDirectory: downloads)
        let groups = try await scanner.scan(excluding: [])

        let kept = try #require(groups.first?.original.url.lastPathComponent)
        #expect(kept == "return copy.pdf")
    }

    @Test func fallsBackToShortestPathThenLexical() async throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        try write("deep/er/same.pdf", in: root)
        try write("b/same.pdf", in: root)
        try write("a/same.pdf", in: root)

        let groups = try await DuplicateScanner(roots: [root]).scan(excluding: [])

        let kept = try #require(groups.first?.original.url.path)
        #expect(kept.hasSuffix("/a/same.pdf"))
    }

    // MARK: - Similar-image scan

    @Test func similarScanOffersNothingFromInsideProjects() async throws {
        let root = try makeRoot()
        defer { TestHelpers.tearDownTempDirectory(root) }
        for path in ["Pictures/a.png", "Pictures/b.png", "proj/node_modules/x/c.png", ".hidden/d.png"] {
            try writePNG(path, in: root)
        }

        let groups = try await SimilarImageScanner(roots: [root]).scan(excluding: [])

        let names = Set(groups.flatMap { $0.files.map(\.url.lastPathComponent) })
        #expect(names == ["a.png", "b.png"])
    }

    /// A solid-colour PNG, so every call yields an identical feature print.
    private func writePNG(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
