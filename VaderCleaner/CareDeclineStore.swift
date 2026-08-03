// CareDeclineStore.swift
// Persisted count of how many Run passes in a row the user has left each kind of finding alone — the memory behind quieting work they keep passing on.

import Foundation
import Observation

/// UserDefaults-backed record of consecutive declines, keyed by finding kind.
///
/// Deliberately the smallest record that answers the question: a kind
/// identifier and an integer. No paths, no filenames, no timestamps — nothing
/// here can describe a file the user owns, only which *categories* of
/// housekeeping they keep passing on. `SettingsGeneralTab`'s Clear History
/// wipes it alongside the receipt log, so one action forgets everything the
/// app has recorded about how the Mac is used.
///
/// The `UserDefaults` instance is injected so tests use an isolated suite, the
/// same seam every other store in the app uses.
@MainActor
@Observable
final class CareDeclineStore {

    private enum Key {
        static let counts = "smartScan.declines.counts"
    }

    /// Consecutive declines per kind. A kind is absent until it is declined
    /// once, and removed again the moment the user acts on it.
    private(set) var counts: [CareFinding.Kind: Int]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Unknown keys are dropped rather than carried: a kind retired in a
        // later build must not linger as a count nothing can ever reset.
        // Corrupt data degrades to empty — this record is a nicety and must
        // never break a scan.
        let stored = defaults.dictionary(forKey: Key.counts) ?? [:]
        var decoded: [CareFinding.Kind: Int] = [:]
        for (rawKind, value) in stored {
            guard let kind = CareFinding.Kind(rawValue: rawKind),
                  let count = value as? Int, count > 0 else { continue }
            decoded[kind] = count
        }
        self.counts = decoded
    }

    /// How many Run passes in a row have left this kind alone.
    func declineCount(for kind: CareFinding.Kind) -> Int {
        counts[kind] ?? 0
    }

    var isEmpty: Bool { counts.isEmpty }

    /// Folds one Run pass's choices in: every declined kind's streak grows,
    /// every acted-on kind's streak resets. Acting is a stronger signal than
    /// passing, so a kind appearing in both is treated as accepted.
    func record(declined: Set<CareFinding.Kind>, accepted: Set<CareFinding.Kind>) {
        for kind in declined where !accepted.contains(kind) {
            counts[kind, default: 0] += 1
        }
        for kind in accepted {
            counts.removeValue(forKey: kind)
        }
        persist()
    }

    /// Forgets every recorded decline. Offered through the same Settings
    /// affordance that clears scan history.
    func clear() {
        counts = [:]
        defaults.removeObject(forKey: Key.counts)
    }

    private func persist() {
        guard !counts.isEmpty else {
            defaults.removeObject(forKey: Key.counts)
            return
        }
        defaults.set(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
            forKey: Key.counts
        )
    }
}
