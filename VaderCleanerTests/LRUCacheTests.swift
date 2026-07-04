// LRUCacheTests.swift
// Pins the LRUCache contract: capacity-bounded storage, least-recently-used eviction, and read-refreshed recency.

import XCTest
@testable import VaderCleaner

final class LRUCacheTests: XCTestCase {

    func test_storesAndRetrievesValues() {
        var cache = LRUCache<String, Int>(capacity: 4)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")

        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "b"), 2)
        XCTAssertNil(cache.value(forKey: "missing"))
    }

    func test_countNeverExceedsCapacity() {
        var cache = LRUCache<Int, Int>(capacity: 8)
        for i in 0..<100 { cache.setValue(i, forKey: i) }

        XCTAssertLessThanOrEqual(cache.count, 8)
        XCTAssertEqual(cache.value(forKey: 99), 99, "The newest entry always survives")
    }

    func test_evictsLeastRecentlyUsedFirst() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "old")
        cache.setValue(2, forKey: "new")
        cache.setValue(3, forKey: "newest") // over capacity → evicts "old"

        XCTAssertNil(cache.value(forKey: "old"))
        XCTAssertEqual(cache.value(forKey: "newest"), 3)
    }

    func test_readRefreshesRecency() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        _ = cache.value(forKey: "a")   // "a" is now more recent than "b"
        cache.setValue(3, forKey: "c") // over capacity → evicts "b", not "a"

        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertNil(cache.value(forKey: "b"))
    }

    func test_updatingExistingKeyDoesNotGrowCount() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "a")

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(forKey: "a"), 2)
    }
}
