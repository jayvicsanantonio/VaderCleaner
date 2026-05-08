// Browser.swift
// Stable enum of supported browsers for the Privacy feature, carrying bundle / display / app-name metadata used by detection and data-path resolution.

import Foundation

/// Browsers the Privacy feature can detect, preview, and clear data for.
///
/// Raw values are persisted in scan reports and view-model state, so cases
/// must be appended (never inserted) and existing raw values must not change
/// or older preferences/reports will fail to decode.
///
/// Each case carries:
///   - `bundleIdentifier` — used by future Launch Services lookups.
///   - `appBundleName` — the `.app` filename `BrowserDetector` looks for
///     under `/Applications` and `~/Applications`.
///   - `displayName` — human-readable label shown in the Privacy UI.
enum Browser: String, CaseIterable, Codable, Hashable, Identifiable {
    case safari
    case chrome
    case firefox
    case brave
    case arc
    case opera
    case edge

    var id: String { rawValue }

    /// The shipping bundle identifier. Pinned in tests because a typo would
    /// silently mis-detect a browser as not installed.
    var bundleIdentifier: String {
        switch self {
        case .safari:  return "com.apple.Safari"
        case .chrome:  return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .brave:   return "com.brave.Browser"
        case .arc:     return "company.thebrowser.Browser"
        case .opera:   return "com.operasoftware.Opera"
        case .edge:    return "com.microsoft.edgemac"
        }
    }

    /// The `.app` filename as it appears under `/Applications`. The display
    /// name and bundle filename diverge enough across vendors (Brave → "Brave
    /// Browser.app", Edge → "Microsoft Edge.app") that a single derivation
    /// rule wouldn't be reliable; case-by-case is the only correct option.
    var appBundleName: String {
        switch self {
        case .safari:  return "Safari.app"
        case .chrome:  return "Google Chrome.app"
        case .firefox: return "Firefox.app"
        case .brave:   return "Brave Browser.app"
        case .arc:     return "Arc.app"
        case .opera:   return "Opera.app"
        case .edge:    return "Microsoft Edge.app"
        }
    }

    /// Label shown in the Privacy UI's per-browser disclosure header.
    var displayName: String {
        switch self {
        case .safari:  return "Safari"
        case .chrome:  return "Google Chrome"
        case .firefox: return "Firefox"
        case .brave:   return "Brave"
        case .arc:     return "Arc"
        case .opera:   return "Opera"
        case .edge:    return "Microsoft Edge"
        }
    }
}
