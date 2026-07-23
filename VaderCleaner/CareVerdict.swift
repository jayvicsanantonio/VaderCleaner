// CareVerdict.swift
// Pure derivation of the care-plan hero verdict: a health tier from telemetry, capped by finding severity, with plain-language headline and detail.

import Foundation

/// What the results hero says about the Mac as a whole: the five-tier status
/// (drives the ring fill and tint) plus a headline and one supporting line.
struct CareVerdict: Equatable {
    let status: MacHealthStatus
    let headline: String
    let detail: String
}

/// Deterministic verdict rules, `PerformanceRecommendationEngine`-style: no
/// state, no I/O, fully unit-testable. The base tier comes from the shared
/// Health Monitor derivation so Smart Scan and the Health section can never
/// disagree about the same telemetry; findings then only ever *lower* it.
enum CareVerdictEngine {

    /// Safe reclaimable bytes above which the Mac stops reading as pristine —
    /// a machine carrying this much removable junk deserves "Fair" at best.
    static let safeJunkCapBytes: Int64 = 5_000_000_000

    static func verdict(for plan: CarePlan) -> CareVerdict {
        let status = status(for: plan)
        return CareVerdict(
            status: status,
            headline: headline(for: status),
            detail: detail(for: plan)
        )
    }

    /// The tier: telemetry base (defaulting to Good when unmeasured, never
    /// claiming Excellent without evidence), capped down by finding severity.
    static func status(for plan: CarePlan) -> MacHealthStatus {
        let base: MacHealthStatus
        if let health = plan.health,
           let measured = HealthMonitorViewModel.macHealthStatus(
               disk: health.disk, smart: health.smart, battery: health.battery
           ) {
            base = measured
        } else {
            base = .good
        }

        var status = base
        if let threats = plan.finding(.threats), !threats.isEmpty {
            status = min(status, .requiresAttention)
        }
        if safelyFreeableBytes(in: plan) > safeJunkCapBytes {
            status = min(status, .fair)
        }
        return status
    }

    /// Headline per tier — the sentence a non-technical user reads first.
    static func headline(for status: MacHealthStatus) -> String {
        switch status {
        case .excellent:
            return String(localized: "Your Mac is in great shape", comment: "Care verdict headline: excellent.")
        case .good:
            return String(localized: "Your Mac is in good shape", comment: "Care verdict headline: good.")
        case .fair:
            return String(localized: "Your Mac could use a little care", comment: "Care verdict headline: fair.")
        case .requiresAttention:
            return String(localized: "Your Mac needs some attention", comment: "Care verdict headline: requires attention.")
        case .critical:
            return String(localized: "Your Mac needs help right now", comment: "Care verdict headline: critical.")
        }
    }

    /// The supporting line: how many things are worth doing and how much
    /// space is safely freeable. Informational findings are notes, not tasks,
    /// so they never inflate the count.
    static func detail(for plan: CarePlan) -> String {
        detail(for: plan, safeFreeableBytes: safelyFreeableBytes(in: plan))
    }

    /// Same supporting line, but with the count and freeable bytes supplied by
    /// the caller. The results feed passes the *pre-approved* count and its
    /// *selected* bytes so the hero speaks to exactly what Fix will handle —
    /// agreeing with the tiles and the disc caption instead of counting opt-in
    /// items it won't touch or promising the gross total found.
    static func detail(for plan: CarePlan, readyCount: Int, safeFreeableBytes: Int64) -> String {
        if plan.findings.isEmpty {
            return String(
                localized: "Nothing needs your attention right now.",
                comment: "Care verdict detail when the scan found nothing."
            )
        }
        let hasActionable = plan.findings.contains { $0.actionability != .informational }
        if !hasActionable {
            return String(
                localized: "Nothing needs fixing — the notes below are just worth knowing.",
                comment: "Care verdict detail when only informational findings exist."
            )
        }
        if readyCount == 0 {
            // Actionable work exists, but it's all opt-in — nothing Fix handles
            // on its own. Point at the zones below rather than quoting a count.
            return String(
                localized: "Nothing to clean automatically — a few things below are worth a look.",
                comment: "Care verdict detail when only opt-in findings exist."
            )
        }
        if safeFreeableBytes > 0 {
            return String.localizedStringWithFormat(
                String(
                    localized: "%d things worth doing — %@ can be freed safely.",
                    comment: "Care verdict detail: pre-approved count and safely freeable bytes."
                ),
                readyCount,
                CareFindingCopy.formattedBytes(safeFreeableBytes)
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "%d things worth doing.",
                comment: "Care verdict detail: pre-approved count, nothing byte-measurable."
            ),
            readyCount
        )
    }

    /// The plan-only detail kept for surfaces without a live selection (menu
    /// bar, notifications): the actionable count and the gross safely-freeable
    /// total. The results hero uses the `readyCount:safeFreeableBytes:` overload.
    private static func detail(for plan: CarePlan, safeFreeableBytes: Int64) -> String {
        detail(
            for: plan,
            readyCount: plan.findings.filter { $0.actionability != .informational }.count,
            safeFreeableBytes: safeFreeableBytes
        )
    }

    /// Bytes the one-tap Run would free without any review — pre-approved
    /// findings only. Opt-in bytes are the user's call and never counted here.
    static func safelyFreeableBytes(in plan: CarePlan) -> Int64 {
        plan.findings
            .filter { $0.actionability == .preApproved }
            .reduce(0) { $0 + $1.reclaimableBytes }
    }
}
