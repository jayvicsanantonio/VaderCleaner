// DocumentVersionsStoreScanTests.swift
// Drives the shared Document Versions walk against a real directory tree — the rules it enforces only ever run as root inside the helper, so this is the only place they can be checked.

import XCTest
@testable import VaderCleaner

final class DocumentVersionsStoreScanTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentVersionsStoreScanTests/\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - Contents

    func test_entries_reportsRegularFilesWithTheirSizes() throws {
        try write("a.txt", bytes: 10)
        try write("b.txt", bytes: 25)

        let entries = try XCTUnwrap(DocumentVersionsStoreScan().entries(at: root))

        XCTAssertEqual(Set(entries.paths.map { ($0 as NSString).lastPathComponent }), ["a.txt", "b.txt"])
        XCTAssertEqual(entries.sizes.map(\.int64Value).sorted(), [10, 25])
        XCTAssertEqual(entries.paths.count, entries.sizes.count)
    }

    func test_entries_descendsIntoNestedDirectories() throws {
        let nested = root.appendingPathComponent("one/two", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 7).write(to: nested.appendingPathComponent("deep.txt"))

        let entries = try XCTUnwrap(DocumentVersionsStoreScan().entries(at: root))

        // The directories themselves are not regular files and must not be
        // reported — the caller turns every entry into a deletable row.
        XCTAssertEqual(entries.paths.count, 1)
        XCTAssertTrue(entries.paths[0].hasSuffix("one/two/deep.txt"))
        XCTAssertEqual(entries.sizes.map(\.int64Value), [7])
    }

    /// A symlink inside the store would otherwise pull in whatever it points
    /// at — content from outside the store, or a second count of something
    /// already reported.
    func test_entries_skipsSymlinks() throws {
        try write("real.txt", bytes: 4)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: root.appendingPathComponent("real.txt")
        )

        let entries = try XCTUnwrap(DocumentVersionsStoreScan().entries(at: root))

        XCTAssertEqual(entries.paths.map { ($0 as NSString).lastPathComponent }, ["real.txt"])
    }

    // MARK: - Bound

    /// The reply crosses XPC as one message built whole in memory on both
    /// sides, so the walk has to stop somewhere rather than let a
    /// pathological store size the message.
    func test_entries_stopsAtTheLimit() throws {
        for index in 0..<10 {
            try write("file\(index).txt", bytes: 1)
        }

        let entries = try XCTUnwrap(DocumentVersionsStoreScan(limit: 4).entries(at: root))

        XCTAssertEqual(entries.paths.count, 4)
        XCTAssertEqual(entries.sizes.count, 4)
    }

    func test_entries_returnsEverythingBelowTheLimit() throws {
        for index in 0..<3 {
            try write("file\(index).txt", bytes: 1)
        }

        let entries = try XCTUnwrap(DocumentVersionsStoreScan(limit: 100).entries(at: root))

        XCTAssertEqual(entries.paths.count, 3)
    }

    func test_entries_handlesAnEmptyStore() throws {
        let entries = try XCTUnwrap(DocumentVersionsStoreScan().entries(at: root))

        XCTAssertTrue(entries.paths.isEmpty)
        XCTAssertTrue(entries.sizes.isEmpty)
    }

    // MARK: - Helpers

    private func write(_ name: String, bytes: Int) throws {
        try Data(count: bytes).write(to: root.appendingPathComponent(name))
    }
}
