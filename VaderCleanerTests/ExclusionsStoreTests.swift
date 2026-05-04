// ExclusionsStoreTests.swift
// Tests that ExclusionsStore adds, removes, dedupes, and persists excluded paths through an injected UserDefaults.

import XCTest
@testable import VaderCleaner

@MainActor
final class ExclusionsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Per-test suite so persistence assertions never cross-contaminate.
        suiteName = "VaderCleanerTests.ExclusionsStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func test_defaults_isEmpty() {
        let sut = ExclusionsStore(defaults: defaults)
        XCTAssertEqual(sut.exclusions, [])
    }

    // MARK: - Add / remove

    func test_addPath_appendsToList() {
        let sut = ExclusionsStore(defaults: defaults)
        sut.add(path: "/Users/test/Documents")

        XCTAssertEqual(sut.exclusions, ["/Users/test/Documents"])
    }

    func test_addPath_doesNotInsertDuplicates() {
        let sut = ExclusionsStore(defaults: defaults)
        sut.add(path: "/Users/test/Documents")
        sut.add(path: "/Users/test/Documents")

        XCTAssertEqual(sut.exclusions, ["/Users/test/Documents"])
    }

    func test_removePath_removesFromList() {
        let sut = ExclusionsStore(defaults: defaults)
        sut.add(path: "/a")
        sut.add(path: "/b")
        sut.remove(path: "/a")

        XCTAssertEqual(sut.exclusions, ["/b"])
    }

    func test_removePath_unknown_isNoOp() {
        let sut = ExclusionsStore(defaults: defaults)
        sut.add(path: "/a")
        sut.remove(path: "/does-not-exist")

        XCTAssertEqual(sut.exclusions, ["/a"])
    }

    // MARK: - Persistence

    func test_persistsExclusionsAcrossInstances() {
        let writer = ExclusionsStore(defaults: defaults)
        writer.add(path: "/Users/test/Downloads")
        writer.add(path: "/tmp")

        let reader = ExclusionsStore(defaults: defaults)
        XCTAssertEqual(reader.exclusions, ["/Users/test/Downloads", "/tmp"])
    }

    func test_persistsRemovalAcrossInstances() {
        let writer = ExclusionsStore(defaults: defaults)
        writer.add(path: "/a")
        writer.add(path: "/b")
        writer.remove(path: "/a")

        let reader = ExclusionsStore(defaults: defaults)
        XCTAssertEqual(reader.exclusions, ["/b"])
    }
}
