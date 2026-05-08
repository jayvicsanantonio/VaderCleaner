// PrivacyCategory.swift
// Stable enum tagging each kind of privacy data the Privacy feature can preview and clear (browser history, downloads, cookies, cache, saved form data).

import Foundation

/// The kind of privacy data a `(Browser, PrivacyCategory)` pair targets.
///
/// Raw values are persisted in view-model state and selection sets, so cases
/// must be appended (never inserted) and existing raw values must not change.
enum PrivacyCategory: String, CaseIterable, Codable, Hashable, Identifiable {
    case history
    case downloads
    case cookies
    case cache
    case savedForms

    var id: String { rawValue }

    /// Label shown next to the per-category checkbox in the Privacy preview.
    var displayName: String {
        switch self {
        case .history:    return "Browsing History"
        case .downloads:  return "Download History"
        case .cookies:    return "Cookies"
        case .cache:      return "Cached Data"
        case .savedForms: return "Saved Form Data"
        }
    }
}
