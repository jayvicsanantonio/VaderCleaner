// CarePlanRanker.swift
// Deterministic ordering of care-plan findings for the results feed: threats first, then reclaimable space descending, then curated kind order.

import Foundation

/// Orders the results feed the way a person triages: the scary thing first,
/// then the biggest space wins, then the advisory notes. Pure and stable —
/// the same findings always produce the same feed, regardless of the order
/// concurrent sub-scans happened to finish in.
enum CarePlanRanker {

    static func ranked(_ findings: [CareFinding]) -> [CareFinding] {
        findings.sorted { lhs, rhs in
            let lhsCritical = lhs.urgency == .critical
            let rhsCritical = rhs.urgency == .critical
            if lhsCritical != rhsCritical { return lhsCritical }
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return kindIndex(lhs.kind) < kindIndex(rhs.kind)
        }
    }

    /// Tie-break position — `CareFinding.Kind` declaration order is curated
    /// so zero-byte advisories land sensibly (disk warning before updates,
    /// login items last).
    private static func kindIndex(_ kind: CareFinding.Kind) -> Int {
        CareFinding.Kind.allCases.firstIndex(of: kind) ?? CareFinding.Kind.allCases.count
    }
}
