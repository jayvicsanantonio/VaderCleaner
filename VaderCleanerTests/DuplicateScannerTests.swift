// DuplicateScannerTests.swift
// Verifies DuplicateScanner groups byte-identical files (size + content hash), ignores same-size-different-content files, skips empty files, honors exclusions, and orders groups by reclaimable bytes.

import XCTest
@testable import VaderCleaner

final class DuplicateScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func scan(excluding: [URL] = []) async throws -> [DuplicateGroup] {
        try await DuplicateScanner(downloadsURL: root).scan(excluding: excluding)
    }

    func test_groupsByteIdenticalFiles() async throws {
        try write("a.txt", "the quick brown fox")
        try write("b.txt", "the quick brown fox")
        try write("unique.txt", "something else entirely here")

        let groups = try await scan()

        XCTAssertEqual(groups.count, 1, "Exactly one duplicate group expected")
        XCTAssertEqual(Set(groups[0].files.map { $0.url.lastPathComponent }), ["a.txt", "b.txt"])
    }

    func test_groupsThreeWayDuplicates() async throws {
        try write("a.txt", "same bytes")
        try write("b.txt", "same bytes")
        try write("c.txt", "same bytes")

        let groups = try await scan()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 3)
        XCTAssertEqual(groups[0].redundantCopies.count, 2, "One copy is kept; the rest are redundant")
    }

    func test_sameSizeDifferentContentIsNotGrouped() async throws {
        // Equal byte length, different content → same size bucket, different hash.
        try write("a.txt", "AAAAAAAAAA")
        try write("b.txt", "BBBBBBBBBB")

        let groups = try await scan()

        XCTAssertTrue(groups.isEmpty, "Same-size but different-content files must not be grouped")
    }

    func test_emptyFilesAreSkipped() async throws {
        try write("e1.txt", "")
        try write("e2.txt", "")

        let groups = try await scan()

        XCTAssertTrue(groups.isEmpty, "Zero-byte files must not be reported as duplicates")
    }

    func test_excludedPathIsIgnored() async throws {
        try write("a.txt", "dup content")
        let excluded = try write("b.txt", "dup content")

        let groups = try await scan(excluding: [excluded])

        XCTAssertTrue(groups.isEmpty, "Excluding one of two copies leaves no duplicate group")
    }

    func test_reclaimableBytesAndOrdering() async throws {
        // Small dup pair + a larger dup pair → larger group sorts first.
        try write("small1.txt", "abc")
        try write("small2.txt", "abc")
        let big = String(repeating: "Z", count: 5000)
        try write("big1.txt", big)
        try write("big2.txt", big)

        let groups = try await scan()

        XCTAssertEqual(groups.count, 2)
        XCTAssertGreaterThan(groups[0].reclaimableBytes, groups[1].reclaimableBytes,
                             "Groups must be ordered by reclaimable bytes, largest first")
        XCTAssertEqual(groups[0].reclaimableBytes, 5000, "One redundant 5000-byte copy is reclaimable")
    }

    func test_identicalFilesLargerThanPrefixTierAreGrouped() async throws {
        // Bigger than the prefix-hash tier, so grouping must fall through to
        // the full-content hash and still confirm the match.
        let bytes = Data((0..<(DuplicateScanner.prefixHashByteLimit + 4096)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: root.appendingPathComponent("big-a.bin"))
        try bytes.write(to: root.appendingPathComponent("big-b.bin"))

        let groups = try await scan()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map { $0.url.lastPathComponent }), ["big-a.bin", "big-b.bin"])
    }

    func test_samePrefixDifferentTailIsNotGrouped() async throws {
        // Identical through the whole prefix tier, differing only in the final
        // byte — the cheap prefix pass must not be trusted as confirmation.
        var a = Data((0..<(DuplicateScanner.prefixHashByteLimit + 4096)).map { UInt8(truncatingIfNeeded: $0) })
        var b = a
        a[a.count - 1] = 0x00
        b[b.count - 1] = 0xFF
        try a.write(to: root.appendingPathComponent("tail-a.bin"))
        try b.write(to: root.appendingPathComponent("tail-b.bin"))

        let groups = try await scan()

        XCTAssertTrue(groups.isEmpty, "Files sharing only a prefix must not be reported as duplicates")
    }
}
