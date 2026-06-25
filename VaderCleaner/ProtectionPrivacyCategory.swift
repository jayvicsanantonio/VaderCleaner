// ProtectionPrivacyCategory.swift
// The privacy data categories the Protection Manager surfaces per browser — a richer set than the file-level PrivacyCategory, carrying display metadata, removable-vs-informational kind, and whether the category expands into per-item rows.

import Foundation

/// One kind of browser privacy data shown in the Protection Manager. Distinct
/// from `PrivacyCategory` (the Privacy section's file-level model) so this
/// richer set — informational categories, per-item expansion — can evolve
/// without disturbing that soon-to-be-repurposed section.
///
/// Raw values back selection state, so cases must be appended (never inserted)
/// and existing raw values must not change.
enum ProtectionPrivacyCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case autofillValues
    case browsingHistory
    case cookies
    case downloadsHistory
    case savedPasswords
    case searchQueries
    case cachedFiles
    case tabsFromLastSession

    var id: String { rawValue }

    /// Whether the manager lets the user remove this category, or shows it
    /// read-only with an info popover. Passwords and autofill are never removed
    /// by the manager (CleanMyMac treats them as informational for safety).
    enum Kind: Sendable { case removable, informational }

    /// Matches the reference: Cookies, Downloads History, Cached Files, and
    /// Tabs are removable; Autofill, Browsing History, Saved Passwords, and
    /// Search Queries are shown for awareness (an "i" popover, no checkbox).
    var kind: Kind {
        switch self {
        case .cookies, .downloadsHistory, .cachedFiles, .tabsFromLastSession:
            return .removable
        case .autofillValues, .browsingHistory, .savedPasswords, .searchQueries:
            return .informational
        }
    }

    /// Whether the category expands into per-item rows (Cookies → one row per
    /// domain, Downloads → per site). Only the removable database-backed
    /// categories enumerate individual items.
    var isExpandable: Bool {
        switch self {
        case .cookies, .downloadsHistory:
            return true
        case .autofillValues, .browsingHistory, .savedPasswords, .searchQueries,
             .cachedFiles, .tabsFromLastSession:
            return false
        }
    }

    /// Asset-catalog name of the glossy badge, baked from `Scripts/ScanBadges`.
    var iconAsset: String {
        switch self {
        case .autofillValues:      return "scanBadgeAutofill"
        case .browsingHistory:     return "scanBadgeBrowsingHistory"
        case .cookies:             return "scanBadgeCookies"
        case .downloadsHistory:    return "scanBadgeDownloadsHistory"
        case .savedPasswords:      return "scanBadgeSavedPasswords"
        case .searchQueries:       return "scanBadgeSearchQueries"
        case .cachedFiles:         return "scanBadgeCachedFiles"
        case .tabsFromLastSession: return "scanBadgeTabs"
        }
    }

    var displayName: String {
        switch self {
        case .autofillValues:      return String(localized: "Autofill Values", comment: "Protection privacy category.")
        case .browsingHistory:     return String(localized: "Browsing History", comment: "Protection privacy category.")
        case .cookies:             return String(localized: "Cookies", comment: "Protection privacy category.")
        case .downloadsHistory:    return String(localized: "Downloads History", comment: "Protection privacy category.")
        case .savedPasswords:      return String(localized: "Saved Passwords", comment: "Protection privacy category.")
        case .searchQueries:       return String(localized: "Search Queries", comment: "Protection privacy category.")
        case .cachedFiles:         return String(localized: "Cached Files", comment: "Protection privacy category.")
        case .tabsFromLastSession: return String(localized: "Tabs From Last Session", comment: "Protection privacy category.")
        }
    }

    /// Explanation shown in the info popover (informational categories) or as
    /// the per-pane subheading.
    var info: String {
        switch self {
        case .autofillValues:
            return String(localized: "Form data your browser has saved to autofill fields. Shown for your awareness; the manager never removes it.", comment: "Protection privacy category info.")
        case .browsingHistory:
            return String(localized: "The list of sites you've visited.", comment: "Protection privacy category info.")
        case .cookies:
            return String(localized: "Small files sites store on your Mac to remember you between visits.", comment: "Protection privacy category info.")
        case .downloadsHistory:
            return String(localized: "The record of files you've downloaded (not the files themselves).", comment: "Protection privacy category info.")
        case .savedPasswords:
            return String(localized: "Credentials your browser has saved. Shown for your awareness; the manager never removes them.", comment: "Protection privacy category info.")
        case .searchQueries:
            return String(localized: "Terms you've typed into the address bar and search boxes.", comment: "Protection privacy category info.")
        case .cachedFiles:
            return String(localized: "Temporary files browsers store to load pages faster.", comment: "Protection privacy category info.")
        case .tabsFromLastSession:
            return String(localized: "Tabs your browser remembers from the previous session.", comment: "Protection privacy category info.")
        }
    }
}
