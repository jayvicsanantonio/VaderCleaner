// CarePlan.swift
// The aggregated result of one Smart Scan: the findings feed, a health telemetry snapshot, and an honest per-unit outcome record.

import Foundation

/// Why a scan unit did not run at all.
public enum CareSkipReason: Equatable, Sendable {
    /// The user excluded the unit's domain in Customize Smart Care.
    case disabledInSettings
    /// The malware engine (ClamAV) is not installed or not usable.
    case clamAVUnavailable
}

/// How one scan unit ended. The feed uses these to say truthfully what was
/// checked, what was skipped, and what couldn't be checked — a unit failure
/// never silently disappears into an "all clean" verdict.
public enum CareUnitOutcome: Equatable, Sendable {
    case completed
    case skipped(CareSkipReason)
    case failed(message: String)
}

/// Cheap system telemetry captured alongside the scan, read from the
/// app-scoped `SystemStatsService`'s already-published values. SMART is the
/// last cached reading — the scan never spawns the slow `diskutil` probe.
public struct CareHealthSnapshot: Equatable, Sendable {
    let disk: DiskStats
    let memoryPressure: MemoryPressureLevel
    let smart: SMARTStatus
    let battery: BatteryAvailability
}

/// Everything one Smart Scan produced. Immutable and Sendable so it can be
/// built off the main actor and handed to the view model in one hop.
public struct CarePlan: Equatable, Sendable {

    /// Findings with work to show, unranked — `CarePlanRanker` orders the
    /// feed. Empty findings are dropped at aggregation time.
    let findings: [CareFinding]

    /// Telemetry snapshot, or `nil` when the stats service had no readings.
    let health: CareHealthSnapshot?

    /// Outcome of every unit the scan attempted or deliberately skipped.
    let unitOutcomes: [CareScanUnit: CareUnitOutcome]

    let startedAt: Date
    let finishedAt: Date

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(
        findings: [CareFinding],
        health: CareHealthSnapshot?,
        unitOutcomes: [CareScanUnit: CareUnitOutcome],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.findings = findings
        self.health = health
        self.unitOutcomes = unitOutcomes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Whether the malware unit genuinely ran to completion — the flag other
    /// sections (Protection's dashboard prewarm) key off.
    public var malwareScanPerformed: Bool {
        unitOutcomes[.malware] == .completed
    }

    /// The finding of the given kind, or `nil` when the scan found no such
    /// work (or the unit didn't run).
    public func finding(_ kind: CareFinding.Kind) -> CareFinding? {
        findings.first { $0.kind == kind }
    }

    /// Units that errored, in stable declaration order, for the coverage
    /// footnote ("We couldn't check …").
    public var failedUnits: [CareScanUnit] {
        CareScanUnit.allCases.filter {
            if case .failed = unitOutcomes[$0] { return true }
            return false
        }
    }

    /// Whether this scan produced nothing it can stand behind: every unit it
    /// actually attempted failed — or, vacuously, it attempted none at all.
    ///
    /// The health snapshot is deliberately not an attempt. It rides along on
    /// every scan and has no failure path, so counting it would leave a scan
    /// whose every real check failed still holding one `.completed` unit —
    /// enough to pass as a partial success and land on the results feed under
    /// "Your Mac is in good shape".
    var everyCheckFailed: Bool {
        let attempted = CareScanUnit.allCases.filter { unit in
            guard unit != .healthSnapshot else { return false }
            switch unitOutcomes[unit] {
            case .completed, .failed: return true
            case .skipped, nil: return false
            }
        }
        return attempted.allSatisfy { unit in
            if case .failed = unitOutcomes[unit] { return true }
            return false
        }
    }

    /// Units deliberately not run, in stable declaration order.
    public var skippedUnits: [CareScanUnit] {
        CareScanUnit.allCases.filter {
            if case .skipped = unitOutcomes[$0] { return true }
            return false
        }
    }

    /// This plan without the findings for `units` — the interim feed shown while
    /// a targeted re-scan re-checks them. Outcomes stay as they were: the units
    /// did run, and the coverage footnote still speaks for that scan.
    func removingFindings(for units: Set<CareScanUnit>) -> CarePlan {
        CarePlan(
            findings: findings.filter { !units.contains($0.kind.unit) },
            health: health,
            unitOutcomes: unitOutcomes,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    /// This plan without the items at `urls`, for the findings a Run pass didn't
    /// re-scan. Findings overlap: Duplicates, Downloads, Large & Old Files, and
    /// Installers all walk the same folders, and one app can be unused, unsupported,
    /// and due an update. So removing a file through one card leaves it stale on
    /// the others. Pruned in place because re-scanning those cards would throw away
    /// what the user chose on them. A group left with one file has nothing to
    /// compare, and the first file left in a group becomes its kept original.
    ///
    /// Junk is left alone: its payload can run to a million files, and the deleter
    /// already treats a file that has gone as nothing to do.
    func removingItems(at urls: Set<URL>) -> CarePlan {
        guard !urls.isEmpty else { return self }
        let pruned = findings.map { finding -> CareFinding in
            switch finding.payload {
            case .threats(let threats):
                return CareFinding(payload: .threats(threats.filter { !urls.contains($0.filePath) }))
            case .duplicates(let groups):
                return CareFinding(payload: .duplicates(groups.compactMap { group in
                    let files = group.files.filter { !urls.contains($0.url) }
                    return files.count > 1 ? DuplicateGroup(files: files) : nil
                }))
            case .similarImages(let groups):
                return CareFinding(payload: .similarImages(groups.compactMap { group in
                    let files = group.files.filter { !urls.contains($0.url) }
                    return files.count > 1 ? SimilarImageGroup(files: files) : nil
                }))
            case .downloads(let items):
                return CareFinding(payload: .downloads(items.filter { !urls.contains($0.file.url) }))
            case .largeOldFiles(let files):
                return CareFinding(payload: .largeOldFiles(files.filter { !urls.contains($0.url) }))
            case .installers(let files):
                return CareFinding(payload: .installers(files.filter { !urls.contains($0.url) }))
            case .unusedApps(let apps):
                return CareFinding(payload: .unusedApps(apps.filter { !urls.contains($0.app.bundleURL) }))
            case .unsupportedApps(let apps):
                return CareFinding(payload: .unsupportedApps(apps.filter { !urls.contains($0.app.bundleURL) }))
            case .appUpdates(let updates):
                return CareFinding(payload: .appUpdates(updates.filter { !urls.contains($0.bundleURL) }))
            case .junk, .appLeftovers, .extensions, .backgroundItems, .loginItems,
                 .maintenanceDue, .browserPrivacy, .lowDiskSpace:
                return finding
            }
        }
        return CarePlan(
            findings: pruned.filter { !$0.isEmpty },
            health: health,
            unitOutcomes: unitOutcomes,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    /// This plan with `refreshed` substituted in for `units` — the units a Run
    /// pass acted on and a targeted re-scan has just re-checked.
    ///
    /// Findings and outcomes for those units come from `refreshed`, so work that
    /// is genuinely gone disappears instead of lingering as a stale card. Every
    /// other finding is carried forward, and re-walking the filesystem to
    /// rediscover it is what made a post-run re-scan expensive.
    /// `removingItems(at:)` is what keeps those carried findings true.
    ///
    /// Health rides along on every re-scan (a cleanup changes free space), but a
    /// refresh that captured none keeps the earlier reading rather than blanking
    /// the verdict hero. Dates span the original scan through the re-check: the
    /// plan began when the user's scan began and is current as of now.
    func merging(_ refreshed: CarePlan, for units: Set<CareScanUnit>) -> CarePlan {
        var outcomes = unitOutcomes
        for unit in units {
            outcomes[unit] = refreshed.unitOutcomes[unit]
        }
        return CarePlan(
            findings: findings.filter { !units.contains($0.kind.unit) }
                + refreshed.findings.filter { units.contains($0.kind.unit) && !$0.isEmpty },
            health: refreshed.health ?? health,
            unitOutcomes: outcomes,
            startedAt: startedAt,
            finishedAt: refreshed.finishedAt
        )
    }
}
