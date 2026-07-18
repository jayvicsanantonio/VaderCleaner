// CareHistoryStore.swift
// Persisted Smart Scan history: last-scan date, lifetime bytes freed, and a capped log of Run receipts — the memory behind "since last scan" copy.

import Foundation
import Observation

/// UserDefaults-backed scan history. Small by design: a date, a running
/// total, and the most recent receipts (capped) so the feed and the receipt
/// screen can tell the user what Smart Scan has done for them over time.
/// The `UserDefaults` instance is injected so tests use an isolated suite,
/// the same seam every other store in the app uses.
@MainActor
@Observable
final class CareHistoryStore {

    private enum Key {
        static let lastScanDate = "smartScan.history.lastScanDate"
        static let cumulativeBytesFreed = "smartScan.history.cumulativeBytesFreed"
        static let receipts = "smartScan.history.receipts"
    }

    /// Receipts kept beyond this are dropped oldest-first — enough history
    /// to be interesting, small enough for UserDefaults.
    static let maxReceipts = 24

    private(set) var lastScanDate: Date?
    private(set) var cumulativeBytesFreed: Int64
    private(set) var receipts: [CareReceipt]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let interval = defaults.object(forKey: Key.lastScanDate) as? TimeInterval {
            self.lastScanDate = Date(timeIntervalSinceReferenceDate: interval)
        } else {
            self.lastScanDate = nil
        }
        self.cumulativeBytesFreed = (defaults.object(forKey: Key.cumulativeBytesFreed) as? NSNumber)?.int64Value ?? 0
        // Corrupt or from-the-future data degrades to an empty log — history
        // is a nicety and must never break a scan.
        if let data = defaults.data(forKey: Key.receipts),
           let decoded = try? JSONDecoder().decode([CareReceipt].self, from: data) {
            self.receipts = decoded
        } else {
            self.receipts = []
        }
    }

    /// Stamps a completed scan so future sessions can say when the Mac was
    /// last checked.
    func recordScan(at date: Date = Date()) {
        lastScanDate = date
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Key.lastScanDate)
    }

    /// Appends a Run receipt, growing the lifetime freed total and trimming
    /// the log to the newest `maxReceipts`.
    func recordReceipt(_ receipt: CareReceipt) {
        cumulativeBytesFreed += receipt.totalBytesFreed
        receipts.append(receipt)
        if receipts.count > Self.maxReceipts {
            receipts.removeFirst(receipts.count - Self.maxReceipts)
        }
        defaults.set(NSNumber(value: cumulativeBytesFreed), forKey: Key.cumulativeBytesFreed)
        if let data = try? JSONEncoder().encode(receipts) {
            defaults.set(data, forKey: Key.receipts)
        }
    }

    /// One line of lifetime progress for the feed hero and the receipt:
    /// how much Smart Scan has freed in total. `nil` until something has
    /// actually been freed, so the line never brags about nothing.
    func lifetimeFreedLine() -> String? {
        guard cumulativeBytesFreed > 0 else { return nil }
        return String.localizedStringWithFormat(
            String(
                localized: "%@ freed so far with Smart Scan.",
                comment: "History line: lifetime bytes freed across every Run pass."
            ),
            CareFindingCopy.formattedBytes(cumulativeBytesFreed)
        )
    }
}
