// CareSeverity.swift
// Derives how loudly a care-plan finding should lead from its magnitude and the Mac's disk pressure, rather than from its kind alone.

import Foundation

/// Why a finding scored the way it did. Signals are what let the feed explain
/// itself — a card that outranks a larger one should be able to say why.
enum CareSignal: Equatable, Sendable {
    /// The finding is large relative to what its kind usually turns up.
    case magnitude
    /// Free space is short enough that reclaiming it matters more than usual.
    case diskPressure
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

    /// The context for surfaces with no telemetry to consult. Findings resolve
    /// to their kind-derived tier and a pure magnitude score.
    static let none = CareSeverityContext(health: nil)
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

    /// Magnitude at or above which the `.magnitude` signal fires.
    static let magnitudeSignalThreshold = 0.9

    /// Score weights. Magnitude carries the ordering; disk pressure is a
    /// deliberate nudge, large enough to lift a safe win over a comparable
    /// peer and too small to outrank a finding an order of magnitude bigger.
    static let magnitudeWeight = 0.85
    static let pressureWeight = 0.15

    // MARK: - Derivation

    static func severity(for finding: CareFinding, context: CareSeverityContext) -> CareSeverity {
        var signals: [CareSignal] = []

        let magnitude = magnitude(of: finding)
        if magnitude >= magnitudeSignalThreshold {
            signals.append(.magnitude)
        }

        let isCriticallyFull = reportsCriticallyFullDisk(finding)
        let isBoosted = qualifiesForPressureBoost(finding, context: context)
        if isCriticallyFull || isBoosted {
            signals.append(.diskPressure)
        }

        // Escalation only raises: a finding never drops below the tier its kind
        // guarantees, whatever the telemetry says.
        let urgency = isCriticallyFull ? max(finding.urgency, .critical) : finding.urgency
        let score = min(1.0, magnitudeWeight * magnitude + (isBoosted ? pressureWeight : 0))

        return CareSeverity(urgency: urgency, score: score, signals: signals)
    }

    /// How big this finding is on its own kind's scale, 0...1. Sized findings
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

    private static func clamped(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
