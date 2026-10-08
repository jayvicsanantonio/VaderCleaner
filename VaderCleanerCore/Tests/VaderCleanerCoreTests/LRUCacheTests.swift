// LRUCacheTests.swift
// Pins the LRUCache contract: capacity-bounded storage, least-recently-used eviction, and read-refreshed recency.

import Testing
@testable import VaderCleanerCore

@Suite
struct LRUCacheTests {

    @Test
    func storesAndRetrievesValues() {
        var cache = LRUCache<String, Int>(capacity: 4)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")

        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == 2)
        #expect(cache.value(forKey: "missing") == nil)
    }

    @Test
    func countNeverExceedsCapacity() {
        var cache = LRUCache<Int, Int>(capacity: 8)
        for i in 0..<100 { cache.setValue(i, forKey: i) }

        #expect(cache.count <= 8)
        #expect(cache.value(forKey: 99) == 99, "The newest entry always survives")
    }

    @Test
    func evictsLeastRecentlyUsedFirst() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "old")
        cache.setValue(2, forKey: "new")
        cache.setValue(3, forKey: "newest") // over capacity → evicts "old"

        #expect(cache.value(forKey: "old") == nil)
        #expect(cache.value(forKey: "newest") == 3)
    }

    @Test
    func readRefreshesRecency() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        _ = cache.value(forKey: "a")   // "a" is now more recent than "b"
        cache.setValue(3, forKey: "c") // over capacity → evicts "b", not "a"

        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == nil)
    }

    @Test
    func updatingExistingKeyDoesNotGrowCount() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "a")

        #expect(cache.count == 1)
        #expect(cache.value(forKey: "a") == 2)
    }
}
