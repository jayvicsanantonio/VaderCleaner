// CarePlan.swift
// The aggregated result of one Smart Scan: the findings feed, a health telemetry snapshot, and an honest per-unit outcome record.

import Foundation

/// Why a scan unit did not run at all.
enum CareSkipReason: Equatable, Sendable {
    /// The user excluded the unit's domain in Customize Smart Care.
    case disabledInSettings
    /// The malware engine (ClamAV) is not installed or not usable.
    case clamAVUnavailable
}

/// How one scan unit ended. The feed uses these to say truthfully what was
/// checked, what was skipped, and what couldn't be checked — a unit failure
/// never silently disappears into an "all clean" verdict.
enum CareUnitOutcome: Equatable, Sendable {
    case completed
    case skipped(CareSkipReason)
    case failed(message: String)
}

/// Cheap system telemetry captured alongside the scan, read from the
/// app-scoped `SystemStatsService`'s already-published values. SMART is the
/// last cached reading — the scan never spawns the slow `diskutil` probe.
struct CareHealthSnapshot: Equatable, Sendable {
    let disk: DiskStats
    let memoryPressure: MemoryPressureLevel
    let smart: SMARTStatus
    let battery: BatteryAvailability
}

/// Everything one Smart Scan produced. Immutable and Sendable so it can be
/// built off the main actor and handed to the view model in one hop.
struct CarePlan: Equatable, Sendable {

    /// Findings with work to show, unranked — `CarePlanRanker` orders the
    /// feed. Empty findings are dropped at aggregation time.
    let findings: [CareFinding]

    /// Telemetry snapshot, or `nil` when the stats service had no readings.
    let health: CareHealthSnapshot?

    /// Outcome of every unit the scan attempted or deliberately skipped.
    let unitOutcomes: [CareScanUnit: CareUnitOutcome]

    let startedAt: Date
    let finishedAt: Date

    /// Whether the malware unit genuinely ran to completion — the flag other
    /// sections (Protection's dashboard prewarm) key off.
    var malwareScanPerformed: Bool {
        unitOutcomes[.malware] == .completed
    }

    /// The finding of the given kind, or `nil` when the scan found no such
    /// work (or the unit didn't run).
    func finding(_ kind: CareFinding.Kind) -> CareFinding? {
        findings.first { $0.kind == kind }
    }

    /// Units that errored, in stable declaration order, for the coverage
    /// footnote ("We couldn't check …").
    var failedUnits: [CareScanUnit] {
        CareScanUnit.allCases.filter {
            if case .failed = unitOutcomes[$0] { return true }
            return false
        }
    }

    /// Units deliberately not run, in stable declaration order.
    var skippedUnits: [CareScanUnit] {
        CareScanUnit.allCases.filter {
            if case .skipped = unitOutcomes[$0] { return true }
            return false
        }
    }
}
