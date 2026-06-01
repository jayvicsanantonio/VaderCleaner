// MaintenanceTask.swift
// Catalog of the performance maintenance tasks the Optimization section can run, with display metadata for the "View All Tasks" list and the recommendation cards.

import Foundation

/// One entry in the maintenance-task catalog. Pure display + classification
/// metadata; the actual work is performed by the matching runner wired into
/// `OptimizationViewModel`. Availability that depends on live system state
/// (e.g. whether local snapshots exist) is decided by the recommendation
/// engine, not baked in here — the catalog list itself is fixed.
struct MaintenanceTask: Identifiable, Hashable {

    /// The fixed set of tasks. `requiresHelper` distinguishes privileged tasks
    /// (run through `VaderCleanerHelper`) from the user-level Mail reindex.
    enum Kind: String, CaseIterable {
        case freeUpRAM
        case runMaintenanceScripts
        case flushDNS
        case reindexSpotlight
        case thinTimeMachineSnapshots
        case speedUpMail
    }

    let kind: Kind
    let title: String
    let summary: String
    let icon: String
    let requiresHelper: Bool

    var id: String { kind.rawValue }

    /// The tasks the "Maintenance Tasks Recommended" card counts and runs — the
    /// recurring upkeep cocktail. Free up RAM (its own hero card) and Thin Time
    /// Machine Snapshots (its own card) are surfaced separately, so they are
    /// excluded here to keep the maintenance card's count and action aligned.
    static let maintenanceCocktailKinds: [Kind] = [
        .runMaintenanceScripts, .flushDNS, .reindexSpotlight, .speedUpMail
    ]

    /// The catalog in display order — Free up RAM and Maintenance Scripts first
    /// (the long-standing actions), then the newer system tasks.
    static let catalog: [MaintenanceTask] = [
        MaintenanceTask(
            kind: .freeUpRAM,
            title: String(localized: "Free Up RAM", comment: "Maintenance task title."),
            summary: String(
                localized: "Reclaim inactive memory so active apps have more room to work.",
                comment: "Maintenance task summary for freeing RAM."
            ),
            icon: "memorychip",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .runMaintenanceScripts,
            title: String(localized: "Run Maintenance Scripts", comment: "Maintenance task title."),
            summary: String(
                localized: "Run the system periodic daily, weekly, and monthly scripts.",
                comment: "Maintenance task summary for periodic scripts."
            ),
            icon: "wrench.and.screwdriver",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .flushDNS,
            title: String(localized: "Flush DNS Cache", comment: "Maintenance task title."),
            summary: String(
                localized: "Clear cached DNS records to fix stale lookups and connection slowdowns.",
                comment: "Maintenance task summary for flushing DNS."
            ),
            icon: "network",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .reindexSpotlight,
            title: String(localized: "Reindex Spotlight", comment: "Maintenance task title."),
            summary: String(
                localized: "Rebuild the Spotlight index to restore search speed and accuracy.",
                comment: "Maintenance task summary for reindexing Spotlight."
            ),
            icon: "magnifyingglass",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .thinTimeMachineSnapshots,
            title: String(localized: "Thin Time Machine Snapshots", comment: "Maintenance task title."),
            summary: String(
                localized: "Reclaim disk space from local snapshots without affecting your backups.",
                comment: "Maintenance task summary for thinning Time Machine snapshots."
            ),
            icon: "clock.arrow.circlepath",
            requiresHelper: true
        ),
        MaintenanceTask(
            kind: .speedUpMail,
            title: String(localized: "Speed Up Mail", comment: "Maintenance task title."),
            summary: String(
                localized: "Rebuild the Mail database to improve search and message handling.",
                comment: "Maintenance task summary for speeding up Mail."
            ),
            icon: "envelope",
            requiresHelper: false
        )
    ]
}
