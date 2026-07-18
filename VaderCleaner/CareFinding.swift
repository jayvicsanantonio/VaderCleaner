// CareFinding.swift
// The unified Smart Scan finding model — one care-plan card's worth of results, wrapping a per-domain payload with derived count, bytes, urgency, and actionability.

import Foundation

/// Per-browser privacy-data counts collected at scan time. Count-only by
/// design: enumerating individual cookies/history rows is the Protection
/// Manager's job; Smart Scan just tells the user how much is there.
struct BrowserPrivacySummary: Hashable, Sendable {
    let browser: Browser
    let counts: [ProtectionPrivacyCategory: Int]

    /// Total items across every category for this browser.
    var totalItems: Int { counts.values.reduce(0, +) }
}

/// Selection key for one browser's one privacy category in the Browser
/// Privacy review — removal is whole-category per browser, so this pair is
/// the finest grain the care plan lets the user opt in.
struct BrowserPrivacyKey: Hashable, Sendable {
    let browser: Browser
    let category: ProtectionPrivacyCategory
}

/// What a Run pass may do with a finding, and how its selection is seeded.
/// This is the safety model's single source of truth: nothing seeded as
/// selected may ever destroy data the user can't get back.
enum CareActionability: Equatable, Sendable {
    /// Regenerable, already discarded, or reversible: pre-checked so a
    /// one-tap Run handles it without review.
    case preApproved
    /// Real user data: listed and reviewable, seeded unchecked — removal is
    /// always an explicit choice.
    case optIn
    /// Nothing to remove — facts the user should know, with a link to the
    /// section that manages them.
    case informational
}

/// One unified finding in the care plan. A finding is the model behind one
/// results card: what was found (`payload`), how much of it (`itemCount` /
/// `reclaimableBytes`), how loudly it should lead (`urgency`), and what Run
/// is allowed to do about it (`actionability`).
struct CareFinding: Identifiable, Equatable, Sendable {

    /// Every kind of finding a scan can produce. Raw values are stable keys
    /// used for identity, accessibility identifiers, and receipt persistence
    /// (hence `Codable`). Declaration order is the ranker's tie-break:
    /// advisory kinds late.
    enum Kind: String, CaseIterable, Hashable, Sendable, Codable {
        case threats
        case lowDiskSpace
        case junkCleanup
        case duplicates
        case largeOldFiles
        case unusedApps
        case appLeftovers
        case installers
        case appUpdates
        case maintenanceDue
        case browserPrivacy
        case loginItems

        /// The scan unit that produces this finding — the checklist and the
        /// review screens group findings by the unit's domain.
        var unit: CareScanUnit {
            switch self {
            case .threats: return .malware
            case .lowDiskSpace: return .healthSnapshot
            case .junkCleanup: return .systemJunk
            case .duplicates: return .duplicates
            case .largeOldFiles: return .largeOldFiles
            case .unusedApps: return .unusedApps
            case .appLeftovers: return .appLeftovers
            case .installers: return .installers
            case .appUpdates: return .appUpdates
            case .maintenanceDue: return .maintenanceDue
            case .browserPrivacy: return .browserPrivacy
            case .loginItems: return .loginItems
            }
        }
    }

    /// The typed results backing a finding, one case per kind. Reuses each
    /// service's own model unchanged so no copies of large arrays are made.
    enum Payload: Equatable, Sendable {
        case junk(ScanResult)
        case threats([MalwareThreat])
        case duplicates([DuplicateGroup])
        case largeOldFiles([ScannedFile])
        case unusedApps([UnusedApp])
        case appLeftovers([LeftoverGroup])
        case installers([InstallationFile])
        case appUpdates([UpdateInfo])
        case loginItems([LoginItem])
        case maintenanceDue(taskIDs: [String])
        case browserPrivacy([BrowserPrivacySummary])
        case lowDiskSpace(DiskStats)
    }

    let kind: Kind
    let payload: Payload

    var id: String { kind.rawValue }

    /// How many removable/reviewable things this finding represents. For
    /// duplicates that is redundant copies only (the kept original is never
    /// work); for leftovers it is orphaned apps, not individual files.
    var itemCount: Int {
        switch payload {
        case .junk(let result): return result.items.count
        case .threats(let threats): return threats.count
        case .duplicates(let groups): return groups.reduce(0) { $0 + $1.redundantCopies.count }
        case .largeOldFiles(let files): return files.count
        case .unusedApps(let apps): return apps.count
        case .appLeftovers(let groups): return groups.count
        case .installers(let files): return files.count
        case .appUpdates(let updates): return updates.count
        case .loginItems(let items): return items.count
        case .maintenanceDue(let taskIDs): return taskIDs.count
        case .browserPrivacy(let summaries): return summaries.reduce(0) { $0 + $1.totalItems }
        case .lowDiskSpace: return 1
        }
    }

    /// Bytes freed if every removable item in this finding were removed.
    /// Zero for count-only findings (threats, updates, privacy counts, …).
    var reclaimableBytes: Int64 {
        switch payload {
        case .junk(let result): return result.totalSize
        case .duplicates(let groups): return groups.reduce(0) { $0 + $1.reclaimableBytes }
        case .largeOldFiles(let files): return files.reduce(0) { $0 + $1.size }
        case .unusedApps(let apps): return apps.reduce(0) { $0 + $1.sizeBytes }
        case .appLeftovers(let groups): return groups.reduce(0) { $0 + $1.totalBytes }
        case .installers(let files): return files.reduce(0) { $0 + $1.sizeBytes }
        case .threats, .appUpdates, .loginItems, .maintenanceDue, .browserPrivacy, .lowDiskSpace:
            return 0
        }
    }

    /// A finding with no work is dropped from the plan rather than rendered
    /// as an empty card.
    var isEmpty: Bool { itemCount == 0 }

    /// How loudly the finding should lead the feed and colour its card.
    /// Threats always dominate; byte findings rank as reclaimable space;
    /// advisory kinds ask for attention without alarming.
    var urgency: RecommendationUrgency {
        switch kind {
        case .threats:
            return .critical
        case .lowDiskSpace, .appUpdates, .maintenanceDue, .browserPrivacy, .loginItems:
            return .attention
        case .junkCleanup, .duplicates, .largeOldFiles, .unusedApps, .appLeftovers, .installers:
            return .space
        }
    }

    /// What Run may do with this finding — see `CareActionability`. Junk is
    /// pre-approved at the card level; its per-file seeding still honours
    /// `ScanCategory.isSafeToAutoRemove`, so unsafe categories stay unchecked.
    var actionability: CareActionability {
        switch kind {
        case .junkCleanup, .threats, .duplicates, .appUpdates, .maintenanceDue:
            return .preApproved
        case .largeOldFiles, .unusedApps, .appLeftovers, .installers, .browserPrivacy:
            return .optIn
        case .loginItems, .lowDiskSpace:
            return .informational
        }
    }
}
