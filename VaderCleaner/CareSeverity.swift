// CareSeverity.swift
// Derives how loudly a care-plan finding should lead from its magnitude and the Mac's disk pressure, rather than from its kind alone.

import Foundation

/// Why a finding scored the way it did. Signals are what let the feed explain
/// itself — a card that outranks a larger one should be able to say why.
enum CareSignal: Equatable, Sendable {
    /// Free space is short enough that reclaiming it matters more than usual.
    case diskPressure
    /// A recent Run cleaned this kind and it has come back. Carries the date of
    /// the receipt that cleared it, so the copy can be specific.
    case regrowth(since: Date)
    /// The user has passed on this kind enough times running that the app has
    /// stopped leading with it. The only signal that quiets a finding rather
    /// than raising it, and the only one that reports the user's own history
    /// back to them — so it always shows a note, never a silent reorder.
    case declined(times: Int)
}

/// How loudly a finding should lead, and why. `urgency` keeps the existing
/// four-tier meaning shared with the section dashboards; `score` orders
/// findings within a tier.
struct CareSeverity: Equatable, Sendable {
    let urgency: RecommendationUrgency
    /// Within-tier ordering weight, 0...1. Never displayed — it exists to be
    /// compared, and to blend magnitude with the other signals.
    let score: Double
    /// Signals that fired, in derivation order. Empty is the common case.
    let signals: [CareSignal]
}

/// Everything the severity engine reasons over besides the finding itself.
/// Kept separate from `CarePlan` because severity depends on state the plan
/// does not own, and findings are built off the main actor before that state
/// is reachable.
struct CareSeverityContext: Sendable {
    let health: CareHealthSnapshot?
    /// Past Run receipts, oldest first — the order `CareHistoryStore` keeps.
    let receipts: [CareReceipt]
    /// Reference point for receipt ages. Snapshotted when a plan lands rather
    /// than read per render, so a feed's order never shifts under the user.
    let now: Date
    /// Consecutive Run passes the user has left each kind alone.
    let declines: [CareFinding.Kind: Int]

    init(
        health: CareHealthSnapshot?,
        receipts: [CareReceipt] = [],
        now: Date = Date(),
        declines: [CareFinding.Kind: Int] = [:]
    ) {
        self.health = health
        self.receipts = receipts
        self.now = now
        self.declines = declines
    }

    /// The context for surfaces with no telemetry or history to consult.
    /// Findings resolve to their kind-derived tier and a pure magnitude score.
    static let none = CareSeverityContext(health: nil, receipts: [], now: .distantPast, declines: [:])
}

/// Deterministic severity rules, `PerformanceRecommendationEngine`-style: no
/// state, no I/O, fully unit-testable. Escalation only ever raises a finding
/// above its kind-derived tier — nothing here can quiet a finding down.
enum CareSeverityEngine {

    // MARK: - Constants

    /// Disk thresholds are the Health Monitor's, referenced rather than copied,
    /// so the card, the hero verdict, and the Health section can never disagree
    /// about what "nearly full" means.
    static let diskWarningThreshold = HealthMonitorViewModel.diskWarningThreshold
    static let diskCriticalThreshold = HealthMonitorViewModel.diskCriticalThreshold

    /// Byte total at which a sized finding's magnitude saturates. Sized for a
    /// laptop's startup volume — anything past it is already "as big as this
    /// gets" for ordering purposes.
    static let scoreCeilingBytes: Int64 = 100_000_000_000

    /// A pre-approved finding must free at least this much before disk pressure
    /// promotes it. Below this the boost would shuffle trivia to the top of a
    /// feed the user opened because their disk is full.
    static let diskPressureFloorBytes: Int64 = 1_000_000_000

    /// How recently a Run must have cleaned a kind for its return to count as
    /// regrowth, and how far the signal's weight decays across that span.
    static let regrowthWindowDays = 30.0

    /// A kind counts as regrown once it is back to this fraction of what the
    /// last Run cleared. Below it, the finding is residue rather than a return.
    static let regrowthCountFraction = 0.5

    /// Kinds whose return is worth remarking on at all.
    ///
    /// `junkCleanup` and `maintenanceDue` are deliberately absent, and for the
    /// same reason: both are *designed* to recur. macOS rebuilds its caches,
    /// and a routine tune-up that never came due again would not be routine.
    /// Reporting either as "back since your last cleanup" frames the system
    /// working correctly as a complaint, so those kinds neither score for
    /// regrowth nor mention it.
    static let regrowthKinds: Set<CareFinding.Kind> = [
        .duplicates, .appLeftovers, .installers, .downloads,
    ]

    /// Score weights, summing to 1. Magnitude carries the ordering; disk
    /// pressure is a deliberate nudge, large enough to lift a safe win over a
    /// comparable peer and too small to outrank a finding an order of
    /// magnitude bigger. Recency sits between them: work the user already did
    /// once and is being asked to do again deserves to lead its peers.
    static let magnitudeWeight = 0.60
    static let pressureWeight = 0.15
    static let recencyWeight = 0.25

    /// Consecutive declines before the app takes the hint. Set high enough that
    /// a couple of passes where the user was in a hurry don't read as an
    /// answer — only a settled habit does.
    static let declineThreshold = 3

    /// How much each decline past the threshold quiets a finding, and the
    /// floor it can never sink below. Dampening is deliberately mild and
    /// bounded: the card must keep its place relative to smaller findings, and
    /// a finding the user has passed on is still a finding worth listing.
    static let declineStep = 0.15
    static let declineDampingFloor = 0.5

    // MARK: - Derivation

    static func severity(for finding: CareFinding, context: CareSeverityContext) -> CareSeverity {
        var signals: [CareSignal] = []

        let magnitude = magnitude(of: finding)

        let isCriticallyFull = reportsCriticallyFullDisk(finding)
        let isBoosted = qualifiesForPressureBoost(finding, context: context)
        if isCriticallyFull || isBoosted {
            signals.append(.diskPressure)
        }

        var recency = 0.0
        if regrowthKinds.contains(finding.kind),
           let clearedAt = regrowth(for: finding, context: context) {
            signals.append(.regrowth(since: clearedAt))
            recency = recencyDecay(from: clearedAt, to: context.now)
        }

        // Escalation only raises: a finding never drops below the tier its kind
        // guarantees, whatever the telemetry says. Declines are the one thing
        // that quiets a finding, and they move the score only — a card the user
        // keeps passing on stops leading, but never changes what it is.
        let urgency = isCriticallyFull ? max(finding.urgency, .critical) : finding.urgency
        let raw = min(
            1.0,
            magnitudeWeight * magnitude
                + (isBoosted ? pressureWeight : 0)
                + recencyWeight * recency
        )

        let declines = declineCount(for: finding, context: context)
        if declines >= declineThreshold {
            signals.append(.declined(times: declines))
        }

        return CareSeverity(urgency: urgency, score: raw * damping(forDeclines: declines), signals: signals)
    }

    /// How big this finding is, 0...1 — an ordering weight, never a claim.
    ///
    /// Deliberately not surfaced as a note: the card already prints the size,
    /// and a badge reading "bigger than usual" beside "325.47 GB" says nothing
    /// the number didn't. Saying it honestly would need a per-kind baseline
    /// there is no evidence for; a shared ceiling cannot tell a photo library
    /// from an installer folder.
    ///
    /// Sized findings
    /// measure bytes on a log scale — 40 GB versus 6 GB is a difference worth
    /// ordering on, while 200 MB versus 100 MB is noise that a linear scale
    /// would let dominate. Count-only findings measure against the count at
    /// which that kind stops being routine.
    static func magnitude(of finding: CareFinding) -> Double {
        if finding.reclaimableBytes > 0 {
            let bytes = Double(finding.reclaimableBytes)
            return clamped(log10(bytes) / log10(Double(scoreCeilingBytes)))
        }
        return clamped(Double(finding.itemCount) / Double(notableCount(for: finding.kind)))
    }

    /// The count at which a count-only finding is as loud as it gets. These are
    /// judgement calls about what a person would consider a lot of something,
    /// not measurements.
    static func notableCount(for kind: CareFinding.Kind) -> Int {
        switch kind {
        case .lowDiskSpace:
            return 1
        case .maintenanceDue, .unsupportedApps:
            return 5
        case .threats:
            return 10
        case .appUpdates, .extensions:
            return 20
        case .loginItems:
            return 25
        case .backgroundItems:
            return 30
        case .browserPrivacy:
            return 500
        case .junkCleanup, .duplicates, .largeOldFiles, .unusedApps, .appLeftovers,
             .installers, .similarImages, .downloads:
            // Sized kinds reach this only when they carry no bytes; fall back to
            // a count that keeps them comparable with the advisories.
            return 50
        }
    }

    // MARK: - Rules

    /// Whether this finding reports a disk full enough that the whole verdict
    /// should read critical. Answered from the finding's own payload — it
    /// describes a specific volume, so it must not depend on a telemetry
    /// snapshot that may be missing.
    static func reportsCriticallyFullDisk(_ finding: CareFinding) -> Bool {
        guard case .lowDiskSpace(let stats) = finding.payload else { return false }
        return HealthMonitorViewModel.diskUsageRatio(stats) >= diskCriticalThreshold
    }

    /// Pre-approved findings big enough to matter rise when the disk is filling
    /// up. Opt-in findings never do: the user's own files are their call, and
    /// pressure is not a reason for the app to push harder on data it isn't
    /// allowed to remove unattended.
    private static func qualifiesForPressureBoost(
        _ finding: CareFinding,
        context: CareSeverityContext
    ) -> Bool {
        guard finding.actionability == .preApproved,
              finding.reclaimableBytes > diskPressureFloorBytes,
              let disk = context.health?.disk else { return false }
        return HealthMonitorViewModel.diskUsageRatio(disk) >= diskWarningThreshold
    }

    /// When the most recent Run pass cleared this finding's kind, if it did so
    /// recently enough and the kind has since come back far enough to count.
    ///
    /// Only the newest clearing receipt is consulted: an older one describes a
    /// cleanup that a later pass already superseded, and walking past it would
    /// let ancient history revive a signal the recent record contradicts.
    static func regrowth(for finding: CareFinding, context: CareSeverityContext) -> Date? {
        guard finding.itemCount > 0 else { return nil }
        for receipt in context.receipts.reversed() {
            guard let line = receipt.lines.first(
                where: { $0.kind == finding.kind && $0.itemsProcessed > 0 }
            ) else { continue }

            let age = context.now.timeIntervalSince(receipt.date)
            guard age >= 0, age <= regrowthWindowDays * 86_400 else { return nil }
            guard Double(finding.itemCount) >= Double(line.itemsProcessed) * regrowthCountFraction
            else { return nil }
            return receipt.date
        }
        return nil
    }

    /// How many passes running the user has left this finding alone — counted
    /// only for opt-in findings.
    ///
    /// Opt-in findings are the user's own files, and declining them is a
    /// standing preference the app should respect. Pre-approved findings are
    /// hygiene the app vouches for — junk, duplicates, updates, and above all
    /// threats — and no amount of passing on those is a reason to stop raising
    /// them. Informational findings have nothing to decline.
    private static func declineCount(for finding: CareFinding, context: CareSeverityContext) -> Int {
        guard finding.actionability == .optIn else { return 0 }
        return context.declines[finding.kind] ?? 0
    }

    /// The multiplier a declined finding's score is scaled by: 1 until the
    /// threshold, then easing down to `declineDampingFloor`. Multiplicative
    /// rather than subtractive so a large declined finding still outranks a
    /// trivial one — the app takes the hint without hiding the evidence.
    static func damping(forDeclines times: Int) -> Double {
        guard times >= declineThreshold else { return 1.0 }
        let steps = Double(times - declineThreshold + 1)
        return max(declineDampingFloor, 1.0 - declineStep * steps)
    }

    /// Full weight the day after a cleanup, fading to nothing across the
    /// regrowth window — something back within a week is a louder signal than
    /// something back after a month.
    private static func recencyDecay(from clearedAt: Date, to now: Date) -> Double {
        let window = regrowthWindowDays * 86_400
        guard window > 0 else { return 0 }
        return clamped(1.0 - now.timeIntervalSince(clearedAt) / window)
    }

    private static func clamped(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
