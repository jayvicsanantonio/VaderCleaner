// CareScanEngine.swift
// Concurrent orchestrator for Smart Scan: runs the enabled scan units across five contention-aware lanes, streams lifecycle events, and aggregates a CarePlan.

import Foundation

/// Runs one Smart Scan. The engine owns *how* units execute — concurrency
/// shape, failure isolation, progress clamping, skip bookkeeping — while the
/// actual scanning work is injected as `UnitRunners` closures, so the whole
/// orchestration is unit-testable without touching the disk.
///
/// Concurrency shape: five lanes run in parallel, but units *within* a lane
/// run strictly one after another. Lanes group work that would contend on
/// the same resources (two walkers over Downloads, one library walk, the
/// CPU-bound malware scan, network-bound app metadata, cheap local reads),
/// so wall-clock shrinks without the walks tripping over each other.
struct CareScanEngine: Sendable {

    /// The injected scanning work, one closure per unit. Exclusion lists and
    /// scan scopes are baked in by the live factory, mirroring how
    /// `SmartScanViewModel.live` wired its collaborators.
    struct UnitRunners: Sendable {
        var junk: @Sendable (_ onProgress: @escaping @Sendable (Int) -> Void) async throws -> ScanResult
        var duplicates: @Sendable (_ onProgress: @escaping @Sendable (Int) -> Void) async throws -> [DuplicateGroup]
        var similarImages: @Sendable (_ onProgress: @escaping @Sendable (Int) -> Void) async throws -> [SimilarImageGroup]
        var downloads: @Sendable (_ onProgress: @escaping @Sendable (Int) -> Void) async throws -> [DownloadItem]
        var largeOldFiles: @Sendable (_ onProgress: @escaping @Sendable (Int) -> Void) async throws -> [ScannedFile]
        var malware: @Sendable (_ onProgress: @escaping @Sendable (Int) -> Void) async throws -> [MalwareThreat]
        var installers: @Sendable () async throws -> [InstallationFile]
        var installedApps: @Sendable () async throws -> [AppInfo]
        var appUpdates: @Sendable (_ apps: [AppInfo], _ onProgress: @escaping @Sendable (Int) -> Void) async throws -> [UpdateInfo]
        var unusedApps: @Sendable (_ apps: [AppInfo]) async throws -> [UnusedApp]
        var unsupportedApps: @Sendable (_ apps: [AppInfo]) async throws -> [UnsupportedApp]
        var appLeftovers: @Sendable (_ installedBundleIDs: Set<String>) async throws -> [LeftoverGroup]
        var extensions: @Sendable () async throws -> [ExtensionItem]
        var backgroundItems: @Sendable () async throws -> [LaunchAgent]
        var loginItems: @Sendable () async throws -> [LoginItem]
        var dueMaintenanceTaskIDs: @Sendable () async throws -> [String]
        var browserPrivacy: @Sendable () async throws -> [BrowserPrivacySummary]
        var healthSnapshot: @Sendable () async -> CareHealthSnapshot?
    }

    /// Snapshot of the user's Customize Smart Care choices plus environment
    /// gates, taken once when the scan begins.
    struct Configuration: Sendable {
        var enabledUnits: Set<CareScanUnit>
        var enabledJunkCategories: Set<ScanCategory>
        var malwareEngineAvailable: Bool
    }

    /// Per-unit lifecycle events, emitted as they genuinely happen so the
    /// scanning checklist can fill concurrently and honestly. Progress counts
    /// are already clamped monotonic per unit.
    enum Event: Sendable {
        case unitStarted(CareScanUnit)
        case unitProgress(CareScanUnit, Int)
        case unitFinished(CareScanUnit, CareUnitOutcome, CareFinding?)
    }

    let runners: UnitRunners

    /// Disk-fullness tier at which the plan raises a "disk is getting full"
    /// advisory — aligned with the Health Monitor's Fair boundary so the two
    /// surfaces flag the same disk the same way.
    private static let lowDiskTier: MacHealthStatus = .fair

    /// The five contention-aware lanes, filtered to the enabled units, empty
    /// lanes dropped. Pure so the layout is testable and tunable.
    static func lanes(for units: Set<CareScanUnit>) -> [[CareScanUnit]] {
        let layout: [[CareScanUnit]] = [
            // ~/Library + system junk walk.
            [.systemJunk],
            // User-file walks that overlap on Downloads/Pictures — serialized.
            [.duplicates, .largeOldFiles, .installers, .downloads, .similarImages],
            // CPU-bound content scan over quick paths.
            [.malware],
            // App metadata: one shared discovery, then network + Spotlight.
            [.appUpdates, .unusedApps, .appLeftovers, .unsupportedApps],
            // Cheap local reads.
            [.loginItems, .maintenanceDue, .browserPrivacy, .extensions, .backgroundItems, .healthSnapshot]
        ]
        return layout
            .map { $0.filter(units.contains) }
            .filter { !$0.isEmpty }
    }

    /// Runs the scan and returns the aggregated plan. Never throws: unit
    /// failures are recorded per-unit so one broken scanner can't sink the
    /// results the others produced. Cancelling the calling task cancels
    /// every lane.
    func scan(
        configuration: Configuration,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async -> CarePlan {
        let startedAt = Date()
        var outcomes: [CareScanUnit: CareUnitOutcome] = [:]

        // Record and announce skips up front so the checklist can grey those
        // rows immediately instead of leaving them "waiting" forever.
        var runnableUnits: Set<CareScanUnit> = []
        for unit in CareScanUnit.allCases where configuration.enabledUnits.contains(unit) {
            if unit == .malware && !configuration.malwareEngineAvailable {
                outcomes[.malware] = .skipped(.clamAVUnavailable)
            } else {
                runnableUnits.insert(unit)
            }
        }
        for unit in CareScanUnit.allCases where !configuration.enabledUnits.contains(unit) {
            outcomes[unit] = .skipped(.disabledInSettings)
        }
        for (unit, outcome) in outcomes {
            onEvent(.unitFinished(unit, outcome, nil))
        }

        let lanes = Self.lanes(for: runnableUnits)
        let results = await withTaskGroup(of: [UnitResult].self) { group in
            for lane in lanes {
                group.addTask { [self] in
                    await run(lane: lane, configuration: configuration, onEvent: onEvent)
                }
            }
            var collected: [UnitResult] = []
            for await laneResults in group {
                collected.append(contentsOf: laneResults)
            }
            return collected
        }

        var health: CareHealthSnapshot?
        var findingsByKind: [CareFinding.Kind: CareFinding] = [:]
        for result in results {
            outcomes[result.unit] = result.outcome
            if let snapshot = result.health { health = snapshot }
            if let finding = result.finding, !finding.isEmpty {
                findingsByKind[finding.kind] = finding
            }
        }

        // Deterministic assembly order regardless of which lane finished
        // first — the ranker orders the feed, but equality and tests need a
        // stable baseline.
        let findings = CareFinding.Kind.allCases.compactMap { findingsByKind[$0] }

        return CarePlan(
            findings: findings,
            health: health,
            unitOutcomes: outcomes,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    // MARK: - Lane execution

    /// What one unit's execution produced. `health` rides along only for the
    /// telemetry unit, which contributes plan state beyond a finding.
    private struct UnitResult: Sendable {
        let unit: CareScanUnit
        let outcome: CareUnitOutcome
        let finding: CareFinding?
        var health: CareHealthSnapshot?

        init(unit: CareScanUnit, outcome: CareUnitOutcome, finding: CareFinding?, health: CareHealthSnapshot? = nil) {
            self.unit = unit
            self.outcome = outcome
            self.finding = finding
            self.health = health
        }
    }

    private func run(
        lane: [CareScanUnit],
        configuration: Configuration,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async -> [UnitResult] {
        // The app-metadata lane shares one discovery pass across its units.
        let needsDiscovery = !Set(lane).isDisjoint(with: [.appUpdates, .unusedApps, .appLeftovers, .unsupportedApps])
        var discoveredApps: [AppInfo] = []
        if needsDiscovery {
            onEvent(.unitStarted(lane[0]))
            do {
                discoveredApps = try await runners.installedApps()
            } catch {
                // Discovery is the lane's foundation — without it every app
                // unit fails, each with its own honest outcome.
                return lane.map { unit in
                    let outcome = CareUnitOutcome.failed(message: error.localizedDescription)
                    onEvent(.unitFinished(unit, outcome, nil))
                    return UnitResult(unit: unit, outcome: outcome, finding: nil)
                }
            }
        }

        var results: [UnitResult] = []
        for (index, unit) in lane.enumerated() {
            // The first unit of a discovery lane already announced itself.
            if !(needsDiscovery && index == 0) {
                onEvent(.unitStarted(unit))
            }
            let result = await run(
                unit: unit,
                configuration: configuration,
                apps: discoveredApps,
                onEvent: onEvent
            )
            onEvent(.unitFinished(unit, result.outcome, result.finding))
            results.append(result)
        }
        return results
    }

    private func run(
        unit: CareScanUnit,
        configuration: Configuration,
        apps: [AppInfo],
        onEvent: @escaping @Sendable (Event) -> Void
    ) async -> UnitResult {
        let clamp = MonotonicProgress()
        let progress: @Sendable (Int) -> Void = { count in
            guard let advanced = clamp.advance(to: count) else { return }
            onEvent(.unitProgress(unit, advanced))
        }

        do {
            switch unit {
            case .systemJunk:
                let raw = try await runners.junk(progress)
                let filtered = ScanResult(
                    items: raw.items.filter { configuration.enabledJunkCategories.contains($0.category) }
                )
                return UnitResult(
                    unit: unit,
                    outcome: .completed,
                    finding: CareFinding(kind: .junkCleanup, payload: .junk(filtered))
                )
            case .duplicates:
                let groups = try await runners.duplicates(progress)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .duplicates, payload: .duplicates(groups)))
            case .similarImages:
                let groups = try await runners.similarImages(progress)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .similarImages, payload: .similarImages(groups)))
            case .downloads:
                let items = try await runners.downloads(progress)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .downloads, payload: .downloads(items)))
            case .largeOldFiles:
                let files = try await runners.largeOldFiles(progress)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .largeOldFiles, payload: .largeOldFiles(files)))
            case .malware:
                let threats = try await runners.malware(progress)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .threats, payload: .threats(threats)))
            case .installers:
                let files = try await runners.installers()
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .installers, payload: .installers(files)))
            case .appUpdates:
                let updates = try await runners.appUpdates(apps, progress)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .appUpdates, payload: .appUpdates(updates)))
            case .unusedApps:
                let unused = try await runners.unusedApps(apps)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .unusedApps, payload: .unusedApps(unused)))
            case .unsupportedApps:
                let unsupported = try await runners.unsupportedApps(apps)
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .unsupportedApps, payload: .unsupportedApps(unsupported)))
            case .extensions:
                let items = try await runners.extensions()
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .extensions, payload: .extensions(items)))
            case .backgroundItems:
                let agents = try await runners.backgroundItems()
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .backgroundItems, payload: .backgroundItems(agents)))
            case .appLeftovers:
                let groups = try await runners.appLeftovers(Set(apps.map(\.bundleID)))
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .appLeftovers, payload: .appLeftovers(groups)))
            case .loginItems:
                let items = try await runners.loginItems()
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .loginItems, payload: .loginItems(items)))
            case .maintenanceDue:
                let taskIDs = try await runners.dueMaintenanceTaskIDs()
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .maintenanceDue, payload: .maintenanceDue(taskIDs: taskIDs)))
            case .browserPrivacy:
                let summaries = try await runners.browserPrivacy()
                return UnitResult(unit: unit, outcome: .completed, finding: CareFinding(kind: .browserPrivacy, payload: .browserPrivacy(summaries)))
            case .healthSnapshot:
                let snapshot = await runners.healthSnapshot()
                return UnitResult(
                    unit: unit,
                    outcome: .completed,
                    finding: snapshot.flatMap(Self.lowDiskFinding),
                    health: snapshot
                )
            }
        } catch {
            return UnitResult(unit: unit, outcome: .failed(message: error.localizedDescription), finding: nil)
        }
    }

    /// Raises the "disk is getting full" advisory when the telemetry crosses
    /// the shared Fair boundary (≥ 90% used).
    private static func lowDiskFinding(from snapshot: CareHealthSnapshot) -> CareFinding? {
        guard HealthMonitorViewModel.diskSpaceTier(for: snapshot.disk) <= lowDiskTier else { return nil }
        return CareFinding(kind: .lowDiskSpace, payload: .lowDiskSpace(snapshot.disk))
    }
}

/// Lock-guarded monotonic counter: progress ticks that would move the number
/// backwards (stale phases, out-of-order threads) are dropped at the source,
/// so consumers can trust every emitted count to climb.
private final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var maxValue = 0

    func advance(to value: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard value > maxValue else { return nil }
        maxValue = value
        return value
    }
}
