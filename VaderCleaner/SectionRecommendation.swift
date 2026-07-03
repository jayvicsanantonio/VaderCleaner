// SectionRecommendation.swift
// Shared, deterministic ranking core that turns each section's candidate tiles into the 2–4 recommendations its dashboard shows, ordered so the most important finding leads.

import Foundation

/// How strongly a candidate tile demands attention, independent of size. Ranked
/// above reclaimable space so a safety or urgent finding always leads, matching
/// how an ordinary person reads a cleaner dashboard: fix the scary thing first,
/// then reclaim the most space.
enum RecommendationUrgency: Int, Comparable {
    /// "All good" filler, only used to reach the minimum tile count.
    case reassurance
    /// An ordinary reclaimable-space finding, ranked by how much it frees.
    case space
    /// Needs review but isn't a safety risk (unsupported apps, available
    /// updates, login items).
    case attention
    /// A safety finding that should always lead (malware / threats found).
    case critical

    static func < (lhs: RecommendationUrgency, rhs: RecommendationUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Copy for a reassurance tile — the "all good" card a dashboard shows when it
/// has fewer than the minimum number of real findings. Each section supplies an
/// ordered pool of these so backfilling to the floor never repeats a card.
struct ReassuranceContent: Identifiable, Equatable {
    /// Stable identifier, also used as the card's accessibility identifier stem.
    let id: String
    let title: String
    let detail: String
    /// SF Symbol name for the card's glyph.
    let icon: String
}

/// A rankable tile: an opaque section payload plus the two ranking signals. The
/// payload stays whatever the section already models (an enum, a tile struct),
/// so the selector never dictates a section's rendering.
struct RankedTile<Payload> {
    let payload: Payload
    let urgency: RecommendationUrgency
    /// Reclaimable size in bytes, or `0` when the tile isn't space-based (a
    /// count-only finding such as available updates).
    let reclaimableBytes: Int64

    init(payload: Payload, urgency: RecommendationUrgency, reclaimableBytes: Int64) {
        self.payload = payload
        self.urgency = urgency
        self.reclaimableBytes = reclaimableBytes
    }
}

/// Selects the 2–4 tiles a section dashboard shows from its candidates. Pure and
/// deterministic so it is exhaustively unit-testable; the returned order is the
/// dashboard layout order (the hero leads).
enum SectionRecommendationSelector {

    /// Floor: dashboards always show at least this many tiles, backfilling with
    /// reassurance when there aren't this many real findings.
    static let minimumTiles = 2
    /// Cap: dashboards never show more than this many tiles; lower-ranked real
    /// findings are dropped (still reachable via each section's "Review All").
    static let maximumTiles = 4

    /// Rank `real` by (urgency descending, then reclaimable bytes descending)
    /// with a stable tiebreak on original order, cap the result at
    /// `maximumTiles`, then top up from `reassurance` (in its given order) until
    /// at least `minimumTiles` tiles are present. Reassurance never displaces or
    /// reorders a real finding, and the floor is best-effort: if the reassurance
    /// pool is too small the result can dip below the minimum rather than repeat
    /// a tile.
    static func select<Payload>(real: [RankedTile<Payload>],
                                reassurance: [RankedTile<Payload>]) -> [Payload] {
        // Pair each real candidate with its original index so equal-rank ties
        // resolve to input order — `sorted(by:)` is not guaranteed stable.
        let ranked = real.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.urgency != rhs.element.urgency {
                    return lhs.element.urgency > rhs.element.urgency
                }
                if lhs.element.reclaimableBytes != rhs.element.reclaimableBytes {
                    return lhs.element.reclaimableBytes > rhs.element.reclaimableBytes
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element.payload)

        var selected = Array(ranked.prefix(maximumTiles))

        // Backfill toward the floor with reassurance tiles, in pool order.
        var pool = reassurance.makeIterator()
        while selected.count < minimumTiles, let filler = pool.next() {
            selected.append(filler.payload)
        }

        return selected
    }
}
