// MaintenanceTask.swift
// Catalog of the performance maintenance tasks the Performance section can run, with display metadata for the "View All Tasks" list and the recommendation cards.

import Foundation

/// One entry in the maintenance-task catalog. Pure display + classification
/// metadata; the actual work is performed by the matching runner wired into
/// `PerformanceViewModel`. The catalog list itself is fixed.
public struct MaintenanceTask: Identifiable, Hashable, Sendable {

    /// The fixed set of tasks. `requiresHelper` distinguishes privileged tasks
    /// (run through `VaderCleanerHelper`) from the user-level Mail reindex.
    public enum Kind: String, CaseIterable, Sendable {
        case freeUpRAM
        case runMaintenanceScripts
        case flushDNS
        case reindexSpotlight
        case thinTimeMachineSnapshots
        case speedUpMail
    }

    public let kind: Kind
    public let title: String
    public let summary: String
    public let icon: String
    let requiresHelper: Bool

    public var id: String { kind.rawValue }

    /// The tasks the "Maintenance Tasks Recommended" card counts and Smart Scan
    /// runs — the recurring upkeep cocktail. The rest of the catalog is run on
    /// demand: Free Up RAM and Thin Time Machine Snapshots answer a specific
    /// shortage, and Reindex Spotlight erases an index that takes hours to
    /// rebuild, so nudging anyone to do that weekly would make search worse.
    static let maintenanceCocktailKinds: [Kind] = [
        .runMaintenanceScripts, .flushDNS, .speedUpMail
    ]

    /// The catalog in display order — Free up RAM and Maintenance Scripts first
    /// (the long-standing actions), then the newer system tasks.
    public static let catalog: [MaintenanceTask] = [
        MaintenanceTask(
            kind: .freeUpRAM,
            title: String(localized: "Free Up RAM", bundle: .module, comment: "Maintenance task title."),
            summary: String(
                localized: "Reclaim inactive memory so active apps have more room to work.",
                bundle: .module,
                comment: "Maintenance task summary for freeing RAM."
            ),
            icon: "memorychip",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .runMaintenanceScripts,
            title: String(localized: "Run Maintenance Scripts", bundle: .module, comment: "Maintenance task title."),
            summary: String(
                localized: "Run the system periodic daily, weekly, and monthly scripts.",
                bundle: .module,
                comment: "Maintenance task summary for periodic scripts."
            ),
            icon: "wrench.and.screwdriver",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .flushDNS,
            title: String(localized: "Flush DNS Cache", bundle: .module, comment: "Maintenance task title."),
            summary: String(
                localized: "Clear cached DNS records to fix stale lookups and connection slowdowns.",
                bundle: .module,
                comment: "Maintenance task summary for flushing DNS."
            ),
            icon: "network",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .reindexSpotlight,
            title: String(localized: "Reindex Spotlight", bundle: .module, comment: "Maintenance task title."),
            summary: String(
                localized: "Rebuild the search index when Spotlight misses files. Search is slower until it finishes.",
                bundle: .module,
                comment: "Maintenance task summary for reindexing Spotlight."
            ),
            icon: "magnifyingglass",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .thinTimeMachineSnapshots,
            title: String(localized: "Thin Time Machine Snapshots", bundle: .module, comment: "Maintenance task title."),
            summary: String(
                localized: "Free space held by local snapshots. Your backup disk isn't touched, but recent local restore points may go.",
                bundle: .module,
                comment: "Maintenance task summary for thinning Time Machine snapshots."
            ),
            icon: "clock.arrow.circlepath",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .speedUpMail,
            title: String(localized: "Speed Up Mail", bundle: .module, comment: "Maintenance task title."),
            summary: String(
                localized: "Rebuild the Mail database to improve search and message handling.",
                bundle: .module,
                comment: "Maintenance task summary for speeding up Mail."
            ),
            icon: "envelope",
            requiresHelper: false
        )
    ]
}
