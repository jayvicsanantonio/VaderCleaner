// MaintenanceRunLog.swift
// Persists the last time each maintenance task was run (UserDefaults-backed) so the recommendation engine can flag tasks that are due to run again.

import Foundation

/// Records and reads per-task last-run timestamps. Backed by `UserDefaults`
/// (a single dictionary entry keyed by task id) so the data survives relaunch;
/// the suite is injected so tests use an isolated suite instead of `.standard`.
struct MaintenanceRunLog {

    /// Tasks not run within this window count as stale (due to run again).
    static let staleWindow: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let key = "performance.maintenanceLastRun"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last time the given task id was run, or `nil` if it never has.
    func lastRun(for id: String) -> Date? {
        guard let interval = storedIntervals()[id] else { return nil }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    /// Stamps the given task id as having run at `date` (defaults to now).
    func record(_ id: String, at date: Date = Date()) {
        var intervals = storedIntervals()
        intervals[id] = date.timeIntervalSinceReferenceDate
        defaults.set(intervals, forKey: key)
    }

    /// The given ids that are due to run again — never run, or last run longer
    /// ago than `staleWindow`.
    func staleTaskIDs(among ids: [String], now: Date = Date()) -> [String] {
        ids.filter { id in
            guard let last = lastRun(for: id) else { return true }
            return now.timeIntervalSince(last) > Self.staleWindow
        }
    }

    /// How many of the given ids are due to run again.
    func staleTaskCount(among ids: [String], now: Date = Date()) -> Int {
        staleTaskIDs(among: ids, now: now).count
    }

    private func storedIntervals() -> [String: TimeInterval] {
        defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }
}
