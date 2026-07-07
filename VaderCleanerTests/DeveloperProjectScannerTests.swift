// DeveloperProjectScannerTests.swift
// Drives DeveloperProjectScanner against temp project-tree fixtures — covering name matching, single rolled-up entries, prune-at-match (no double counting nested matches), depth capping, multi-root discovery, and the .webDevJunk tag. Hermetic.

import XCTest
@testable import VaderCleaner

final class DeveloperProjectScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDown() {
        if let tempRoot { TestHelpers.tearDownTempDirectory(tempRoot) }
        tempRoot = nil
        super.tearDown()
    }

    @discardableResult
    private func makeDir(_ relativePath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Deny-list

    func test_junkFolderNames_pinsTheToolchainArtifacts() {
        let names = DeveloperProjectScanner.junkFolderNames
        XCTAssertTrue(names.contains("node_modules"))
        XCTAssertTrue(names.contains("dist"))
        XCTAssertTrue(names.contains("build"))
        XCTAssertTrue(names.contains(".next"))
    }

    // MARK: - Matching & sizing

    func test_scan_emitsOneRolledUpEntryPerMatch_sizedAcrossTheFolder() async throws {
        let modules = try makeDir("projectA/node_modules")
        try TestHelpers.createDummyFile(named: "a.js", size: 100, in: modules)
        try TestHelpers.createDummyFile(named: "b.js", size: 50, in: modules)

        let scanner = DeveloperProjectScanner(roots: [tempRoot])
        let results = await scanner.scan()

        XCTAssertEqual(results.count, 1)
        let entry = try XCTUnwrap(results.first)
        XCTAssertEqual(entry.url.lastPathComponent, "node_modules")
        XCTAssertEqual(entry.url.standardizedFileURL, modules.standardizedFileURL)
        XCTAssertEqual(entry.size, 150)
        XCTAssertEqual(entry.category, .webDevJunk)
    }

    func test_scan_doesNotDescendIntoMatch_nestedMatchCountedInParentTotal() async throws {
        let outer = try makeDir("projectA/node_modules")
        try TestHelpers.createDummyFile(named: "top.js", size: 200, in: outer)
        // A nested node_modules (npm hoisting) must NOT be reported separately —
        // its bytes fold into the outer folder's rolled-up total.
        let nested = try makeDir("projectA/node_modules/dep/node_modules")
        try TestHelpers.createDummyFile(named: "inner.js", size: 30, in: nested)

        let scanner = DeveloperProjectScanner(roots: [tempRoot])
        let results = await scanner.scan()

        XCTAssertEqual(results.count, 1, "Only the outermost match is reported")
        XCTAssertEqual(results.first?.size, 230, "Nested match bytes fold into the parent total")
    }

    func test_scan_ignoresNonJunkFolders() async throws {
        let src = try makeDir("projectA/src")
        try TestHelpers.createDummyFile(named: "main.swift", size: 999, in: src)

        let scanner = DeveloperProjectScanner(roots: [tempRoot])
        let results = await scanner.scan()

        XCTAssertTrue(results.isEmpty)
    }

    func test_scan_matchesMultipleNamesAcrossMultipleRoots() async throws {
        let otherRoot = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(otherRoot) }

        let modules = try makeDir("projectA/node_modules")
        try TestHelpers.createDummyFile(named: "a.js", size: 10, in: modules)
        let dist = otherRoot.appendingPathComponent("projectB/dist", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "bundle.js", size: 20, in: dist)

        let scanner = DeveloperProjectScanner(roots: [tempRoot, otherRoot])
        let results = await scanner.scan()

        XCTAssertEqual(results.count, 2)
        let names = Set(results.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["node_modules", "dist"])
    }

    // MARK: - Depth cap

    func test_scan_honorsMaxDepth_skipsMatchesDeeperThanTheCap() async throws {
        // node_modules is the entry of `b`, reached at root -> a (d1) -> b (d2).
        // With maxDepth 1 we never descend into `b`, so the match is not found.
        let deep = try makeDir("a/b/node_modules")
        try TestHelpers.createDummyFile(named: "x.js", size: 5, in: deep)

        let scanner = DeveloperProjectScanner(roots: [tempRoot], maxDepth: 1)
        let results = await scanner.scan()

        XCTAssertTrue(results.isEmpty, "A match below the depth cap is not reported")
    }

    func test_scan_matchAtRootLevelIsFound() async throws {
        let modules = try makeDir("node_modules")
        try TestHelpers.createDummyFile(named: "a.js", size: 42, in: modules)

        let scanner = DeveloperProjectScanner(roots: [tempRoot], maxDepth: 0)
        let results = await scanner.scan()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.size, 42)
    }

    // MARK: - Robustness

    func test_scan_absentRoot_returnsEmptyWithoutThrowing() async throws {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let scanner = DeveloperProjectScanner(roots: [missing])
        let results = await scanner.scan()
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Progress

    /// The walk reports its cumulative visited tally — directory entries plus
    /// every file sized inside matched artifact folders — so the Cleanup
    /// scanning screen's count keeps moving through big `node_modules` trees.
    func test_scan_reportsTheVisitedTallyThroughOnProgress() async throws {
        let modules = try makeDir("app/node_modules/pkg")
        try TestHelpers.createDummyFiles(count: 4, size: 8, in: modules)
        let recorder = TestHelpers.ProgressRecorder()
        let scanner = DeveloperProjectScanner(roots: [tempRoot])

        _ = await scanner.scan(onProgress: { recorder.record($0) })

        let values = recorder.snapshot
        XCTAssertEqual(values, values.sorted(), "visited tally must be monotonic")
        // At minimum the app dir, the node_modules match, and the four sized
        // files inside it were visited; the final tick reports the total.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values.last), 6)
    }
}
