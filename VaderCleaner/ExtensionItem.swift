// ExtensionItem.swift
// Value type for a single discovered extension / plugin, plus the ExtensionType enum the Extensions Manager groups them under.

import Foundation

/// The categories the Extensions Manager groups discovered items under.
///
/// Raw values are stable identifiers used by the view layer for section
/// identity and accessibility — do not reorder cases or rename raw values
/// without bumping callers.
enum ExtensionType: String, CaseIterable, Identifiable, Sendable {
    case safariExtension
    case chromeExtension
    case firefoxExtension
    case mailPlugin
    case internetPlugin

    var id: String { rawValue }

    /// Human-readable section heading. Localised at the call site (the view
    /// wraps this through `String(localized:)`) so the stable raw value stays
    /// separate from display copy.
    var displayName: String {
        switch self {
        case .safariExtension:  return "Safari Extensions"
        case .chromeExtension:  return "Chrome Extensions"
        case .firefoxExtension: return "Firefox Extensions"
        case .mailPlugin:       return "Mail Plugins"
        case .internetPlugin:   return "Internet Plug-ins"
        }
    }
}

/// A single discovered extension artifact: a Safari/browser extension, a Mail
/// plugin, or an internet plug-in.
///
/// `Identifiable` by `path` so SwiftUI list identity stays stable across
/// re-discovery passes that re-emit the same item; `Hashable` so the
/// view-model can diff item sets without a separate identifier strategy.
struct ExtensionItem: Identifiable, Hashable, Sendable {
    /// Display name — manifest/`Label`/`CFBundleName` derived, falling back
    /// to the filename when no richer source exists.
    let name: String
    /// Absolute on-disk location that removal acts on.
    let path: URL
    /// Owning bundle identifier when one is available — Chrome/Firefox
    /// extensions, `.appex` Safari extensions, Mail plugins, and internet
    /// plug-ins all carry one. `nil` for legacy `.safariextz` archives.
    let bundleID: String?
    let type: ExtensionType
    /// Best-effort enabled state. Defaults to `true` because macOS exposes
    /// no queryable per-extension state for these artifact types.
    let isEnabled: Bool
    /// Recursive byte size of the artifact, used for the row's size label.
    let size: Int64

    var id: URL { path }
}
