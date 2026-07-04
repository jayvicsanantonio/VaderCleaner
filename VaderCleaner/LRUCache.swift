// LRUCache.swift
// Minimal least-recently-used cache — a capacity-bounded dictionary that evicts the stalest entries, used by row-level icon caches so very large scans can't grow them without bound.

import Foundation

/// A small in-memory cache that holds at most `capacity` entries and evicts
/// the least-recently-used ones when full. Recency is tracked with a monotonic
/// tick stamped on every read and write; eviction removes the oldest quarter
/// in one pass so the sort cost is amortized rather than paid per insert at
/// the boundary. Not thread-safe — callers confine it to one actor/thread
/// (the icon caches are main-thread only).
struct LRUCache<Key: Hashable, Value> {

    private struct Entry {
        var value: Value
        var tick: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    /// Returns the cached value and marks it most-recently-used.
    mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        tick &+= 1
        entry.tick = tick
        entries[key] = entry
        return entry.value
    }

    /// Stores (or replaces) a value, evicting the least-recently-used entries
    /// if the cache would exceed its capacity.
    mutating func setValue(_ value: Value, forKey key: Key) {
        tick &+= 1
        entries[key] = Entry(value: value, tick: tick)
        evictIfNeeded()
    }

    private mutating func evictIfNeeded() {
        guard entries.count > capacity else { return }
        // Shrink to 75% of capacity so the next few inserts are eviction-free.
        let target = capacity - capacity / 4
        let staleFirst = entries.sorted { $0.value.tick < $1.value.tick }
        for (key, _) in staleFirst.prefix(entries.count - target) {
            entries.removeValue(forKey: key)
        }
    }
}
