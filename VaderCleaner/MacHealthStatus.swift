// MacHealthStatus.swift
// Overall "Mac Health" verdict (five tiers) with display title and summary copy for the Health Monitor hero card.

import Foundation

/// The single at-a-glance verdict the Health Monitor hero card renders.
///
/// Ordered worst-to-best so the raw values double as a severity index the
/// derivation rule in `HealthMonitorViewModel` can clamp against. The type is
/// deliberately SwiftUI-free — like `StatusColor`, the view layer maps each
/// case to a `Color` once at the leaf so the view-model and its tests need no
/// SwiftUI import.
enum MacHealthStatus: Int, CaseIterable, Comparable {
    case critical = 0
    case requiresAttention = 1
    case fair = 2
    case good = 3
    case excellent = 4

    static func < (lhs: MacHealthStatus, rhs: MacHealthStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short headline word shown large and tinted in the hero card.
    var title: String {
        switch self {
        case .critical:          return String(localized: "Critical")
        case .requiresAttention: return String(localized: "Requires Attention")
        case .fair:              return String(localized: "Fair")
        case .good:              return String(localized: "Good")
        case .excellent:         return String(localized: "Excellent")
        }
    }

    /// Fraction the Health Monitor hero ring fills to (0–1), rising with the
    /// verdict so the arc's length itself signals how healthy the Mac is.
    /// Excellent fills the ring; each worse tier fills less, and even Critical
    /// keeps a visible sliver rather than collapsing to a bare track.
    var score: Double {
        switch self {
        case .critical:          return 0.16
        case .requiresAttention: return 0.36
        case .fair:              return 0.56
        case .good:              return 0.78
        case .excellent:         return 1.0
        }
    }

    /// One-line plain-language explanation shown beneath the title.
    var summary: String {
        switch self {
        case .critical:
            return String(localized: "We strongly recommend taking action to bring your Mac back to normal.")
        case .requiresAttention:
            return String(localized: "Your Mac is not doing well. Run some maintenance to bring it back into shape.")
        case .fair:
            return String(localized: "Your Mac is OK, but some maintenance is recommended to avoid performance issues.")
        case .good:
            return String(localized: "Your Mac is in good shape. Run some maintenance to perform even better.")
        case .excellent:
            return String(localized: "Your Mac is doing great. Run regular maintenance to keep it this way.")
        }
    }
}
