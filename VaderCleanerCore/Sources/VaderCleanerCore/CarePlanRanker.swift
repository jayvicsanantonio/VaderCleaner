// CarePlanRanker.swift
// Deterministic ordering of care-plan findings for the results feed: threats first, then reclaimable space descending, then curated kind order.

import Foundation

/// Orders the results feed the way a person triages: the scary thing first,
/// then the biggest space wins, then the advisory notes. Pure and stable —
/// the same findings always produce the same feed, regardless of the order
/// concurrent sub-scans happened to finish in.
enum CarePlanRanker {

    /// Findings in feed order. `context` supplies the telemetry severity reasons
    /// over; the default reproduces the context-free order for callers that have
    /// none.
    ///
    /// Sized findings stay ahead of count-only ones. The two measure different
    /// things — bytes against a scale, items against what's routine for a kind —
    /// and letting a one-item advisory outscore a real space win on a normalized
    /// number would be comparing scales that don't meet.
    static func ranked(
        _ findings: [CareFinding],
        context: CareSeverityContext = .none
    ) -> [CareFinding] {
        // Severity is derived once per finding rather than inside the
        // comparator, which would recompute it O(n log n) times.
        let severities = Dictionary(
            findings.map { ($0.kind, CareSeverityEngine.severity(for: $0, context: context)) },
            uniquingKeysWith: { first, _ in first }
        )

        return findings.sorted { lhs, rhs in
            let lhsSeverity = severities[lhs.kind]
            let rhsSeverity = severities[rhs.kind]

            let lhsCritical = lhsSeverity?.urgency == .critical
            let rhsCritical = rhsSeverity?.urgency == .critical
            if lhsCritical != rhsCritical { return lhsCritical }

            let lhsSized = lhs.reclaimableBytes > 0
            let rhsSized = rhs.reclaimableBytes > 0
            if lhsSized != rhsSized { return lhsSized }

            let lhsScore = lhsSeverity?.score ?? 0
            let rhsScore = rhsSeverity?.score ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }

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
