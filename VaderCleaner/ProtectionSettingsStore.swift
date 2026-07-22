// ProtectionSettingsStore.swift
// Observable user settings for the Protection scan — content options and scan mode — backed by UserDefaults with a dependency-injected suite for tests.

import Foundation
import Observation

/// How thorough a Protection scan is. Quick checks the persistence vectors —
/// launch agents and browser extensions — for a fast checkup; Balanced walks
/// the whole home with the heavy media/cloud trees excluded; Deep walks the
/// whole home with the fewest exclusions for maximum coverage. Every mode
/// covers the system launch directories. See `MalwareViewModel.scanScope` for
/// the exact roots. The raw value is the persisted key and must stay stable
/// across releases.
enum ScanMode: String, CaseIterable, Identifiable, Sendable {
    case quick
    case balanced
    case deep

    var id: String { rawValue }

    /// Menu/picker label, e.g. "Quick Scan".
    var displayName: String {
        switch self {
        case .quick:    return String(localized: "Quick Scan", comment: "Protection scan mode name.")
        case .balanced: return String(localized: "Balanced Scan", comment: "Protection scan mode name.")
        case .deep:     return String(localized: "Deep Scan", comment: "Protection scan mode name.")
        }
    }

    /// One-word speed characterization shown on the Protection settings tab.
    var speed: String {
        switch self {
        case .quick:    return String(localized: "Fast", comment: "Protection scan mode speed.")
        case .balanced: return String(localized: "Moderate", comment: "Protection scan mode speed.")
        case .deep:     return String(localized: "Slow", comment: "Protection scan mode speed.")
        }
    }

    /// One-word depth characterization shown on the Protection settings tab.
    var depth: String {
        switch self {
        case .quick:    return String(localized: "Key areas", comment: "Protection scan mode depth.")
        case .balanced: return String(localized: "Most files", comment: "Protection scan mode depth.")
        case .deep:     return String(localized: "Every file", comment: "Protection scan mode depth.")
        }
    }

    /// Sentence describing when to use this mode, shown on the settings tab.
    var purpose: String {
        switch self {
        case .quick:
            return String(
                localized: "Checks the startup items and browser extensions that malware uses to stick around after a restart. Good for a regular checkup, or when you're short on time.",
                comment: "Protection Quick Scan purpose."
            )
        case .balanced:
            return String(
                localized: "Goes through all your personal files, including your Downloads and Desktop, plus everything Quick Scan checks. Skips big photo and cloud libraries so it still finishes at a reasonable pace.",
                comment: "Protection Balanced Scan purpose."
            )
        case .deep:
            return String(
                localized: "Looks at every file in your home folder and every startup item, including the photo, video, and cloud libraries the other scans skip. Worth the wait when you want to be certain, or if you think something slipped through.",
                comment: "Protection Deep Scan purpose."
            )
        }
    }
}

/// Source of truth for the Protection section's scan configuration: which
/// content types `clamscan` inspects (email attachments, archives), whether to
/// skip locally-downloaded iCloud files, and how thorough the scan is.
/// Persisted in `UserDefaults` so the choices survive relaunch.
///
/// Defaults mirror the reference design — every content option on and Deep
/// Scan selected — so a fresh install behaves like a thorough, comprehensive
/// sweep. The `UserDefaults` instance is injected so tests can use an
/// isolated suite, the same seam `SmartScanSettingsStore` uses.
@MainActor
@Observable
final class ProtectionSettingsStore {

    private enum Key {
        static let scanEmailAttachments = "protection.scanEmailAttachments"
        static let scanArchives = "protection.scanArchives"
        static let excludeDownloadedICloudFiles = "protection.excludeDownloadedICloudFiles"
        static let scanMode = "protection.scanMode"
    }

    // MARK: - Defaults

    /// On by default: the reference ships both content options checked, and
    /// clamscan inspects mail and archives by default too.
    static let defaultScanEmailAttachments = true
    static let defaultScanArchives = true
    /// On by default: iCloud Drive's local copy mirrors a store Apple already
    /// scans, so skipping it trims scan time with little detection cost.
    static let defaultExcludeDownloadedICloudFiles = true
    /// Quick by default: the persistence vectors only, so a first Protection
    /// scan is fast rather than a whole-$HOME Deep pass. Balanced and Deep
    /// stay one tap away in Protection settings, and both cover the user
    /// folders Quick leaves alone.
    static let defaultScanMode: ScanMode = .quick

    // MARK: - Tracked state

    var scanEmailAttachments: Bool {
        didSet { defaults.set(scanEmailAttachments, forKey: Key.scanEmailAttachments) }
    }

    var scanArchives: Bool {
        didSet { defaults.set(scanArchives, forKey: Key.scanArchives) }
    }

    var excludeDownloadedICloudFiles: Bool {
        didSet { defaults.set(excludeDownloadedICloudFiles, forKey: Key.excludeDownloadedICloudFiles) }
    }

    var scanMode: ScanMode {
        didSet { defaults.set(scanMode.rawValue, forKey: Key.scanMode) }
    }

    // MARK: - Restore defaults

    /// Resets every Protection option to its shipped default. Assigning through
    /// the tracked properties re-runs each `didSet`, so the new values persist.
    func restoreDefaults() {
        scanEmailAttachments = Self.defaultScanEmailAttachments
        scanArchives = Self.defaultScanArchives
        excludeDownloadedICloudFiles = Self.defaultExcludeDownloadedICloudFiles
        scanMode = Self.defaultScanMode
    }

    // MARK: - Init

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Assign each property exactly once so the `didSet` observers above do
        // not fire during init (Swift skips observers for the first assignment
        // inside an initializer). Reading via `object(forKey:) as? T` and
        // falling back to the default keeps a fresh install aligned with the
        // spec rather than UserDefaults' zero values.
        self.scanEmailAttachments = (defaults.object(forKey: Key.scanEmailAttachments) as? Bool)
            ?? Self.defaultScanEmailAttachments
        self.scanArchives = (defaults.object(forKey: Key.scanArchives) as? Bool)
            ?? Self.defaultScanArchives
        self.excludeDownloadedICloudFiles = (defaults.object(forKey: Key.excludeDownloadedICloudFiles) as? Bool)
            ?? Self.defaultExcludeDownloadedICloudFiles
        self.scanMode = (defaults.string(forKey: Key.scanMode)).flatMap(ScanMode.init(rawValue:))
            ?? Self.defaultScanMode
    }
}
