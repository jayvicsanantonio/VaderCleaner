// PerformanceRecommendationEngine.swift
// Turns a snapshot of system state into the curated recommendation cards shown on the Optimization dashboard (Free up RAM, maintenance tasks due, background items, local snapshots).

import Foundation

/// A curated recommendation card surfaced on the Optimization dashboard.
struct PerformanceRecommendation: Identifiable, Hashable {

    /// Each kind maps to one card and one primary action.
    enum Kind: String {
        case freeUpRAM
        case maintenanceTasks
        case backgroundItems
        case thinSnapshots
    }

    let kind: Kind
    let title: String
    let detail: String
    let icon: String
    let actionLabel: String
    /// The single large card on the dashboard (rendered tall on the left,
    /// matching the screenshot). At most one recommendation is the hero.
    let isHero: Bool

    var id: String { kind.rawValue }
}

/// The system state the engine reasons over. Gathered by `OptimizationViewModel`
/// from the shared stats service, the launch-item/agent lists, the local
/// snapshot count, and the maintenance run log.
struct PerformanceSnapshot {
    var memory: MemoryStats
    var localSnapshotCount: Int
    var backgroundItemCount: Int
    var staleTaskCount: Int
}

/// Decides which recommendation cards to surface for a given `PerformanceSnapshot`.
/// Pure and deterministic so it is exhaustively unit-testable; the order of the
/// returned cards is the dashboard layout order.
enum PerformanceRecommendationEngine {

    static func recommendations(for snapshot: PerformanceSnapshot) -> [PerformanceRecommendation] {
        var recommendations: [PerformanceRecommendation] = []

        // RAM is the persistent hero card — always offered, mirroring the
        // Performance dashboard where "Free Up Your RAM" is always present.
        recommendations.append(PerformanceRecommendation(
            kind: .freeUpRAM,
            title: String(
                localized: "Free Up Your RAM",
                comment: "Recommendation card title for freeing memory."
            ),
            detail: String(
                localized: "Make room for more activities in your Mac's memory. Retrieve as much free RAM as possible.",
                comment: "Recommendation card detail for freeing memory."
            ),
            icon: "memorychip",
            actionLabel: String(localized: "Free Up", comment: "Action button on the free-RAM card."),
            isHero: true
        ))

        if snapshot.staleTaskCount > 0 {
            let titleFormat = String(
                localized: "%d Maintenance Tasks Recommended",
                comment: "Recommendation card title; %d is the number of due tasks."
            )
            recommendations.append(PerformanceRecommendation(
                kind: .maintenanceTasks,
                title: String.localizedStringWithFormat(titleFormat, snapshot.staleTaskCount),
                detail: String(
                    localized: "Your maintenance cocktail is ready. Run these tasks to keep your Mac in shape.",
                    comment: "Recommendation card detail for due maintenance tasks."
                ),
                icon: "wrench.and.screwdriver",
                actionLabel: String(localized: "Run Tasks", comment: "Action button on the maintenance-tasks card."),
                isHero: false
            ))
        }

        if snapshot.backgroundItemCount > 0 {
            let titleFormat = String(
                localized: "%d Background Items Found",
                comment: "Recommendation card title; %d is the number of background items."
            )
            recommendations.append(PerformanceRecommendation(
                kind: .backgroundItems,
                title: String.localizedStringWithFormat(titleFormat, snapshot.backgroundItemCount),
                detail: String(
                    localized: "Review login items and launch agents that start automatically with your Mac.",
                    comment: "Recommendation card detail for background items."
                ),
                icon: "gearshape",
                actionLabel: String(localized: "Review", comment: "Action button on the background-items card."),
                isHero: false
            ))
        }

        if snapshot.localSnapshotCount > 0 {
            recommendations.append(PerformanceRecommendation(
                kind: .thinSnapshots,
                title: String(
                    localized: "Thin Time Machine Snapshots",
                    comment: "Recommendation card title for thinning snapshots."
                ),
                detail: String(
                    localized: "Reduce local snapshot storage without affecting your backups.",
                    comment: "Recommendation card detail for thinning snapshots."
                ),
                icon: "clock.arrow.circlepath",
                actionLabel: String(localized: "Run", comment: "Action button on the thin-snapshots card."),
                isHero: false
            ))
        }

        return recommendations
    }
}
