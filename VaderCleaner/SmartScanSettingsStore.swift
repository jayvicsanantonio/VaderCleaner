// SmartScanSettingsStore.swift
// Observable settings for which Smart Scan modules (and System Junk sub-categories) a scan includes — backed by UserDefaults, defaults to everything enabled.

import Foundation
import Observation

/// The five user-facing Smart Scan modules the "Customize Smart Care"
/// preferences persist. Raw values are stable UserDefaults keys. Lives here
/// (with the store that persists it) because the scan itself now runs on
/// `CareScanUnit`/`CareDomain`; the domains reuse these raw values so stored
/// choices keep decoding.
enum SmartScanModule: String, Hashable, CaseIterable {
    case systemJunk
    case malware
    case performance
    case applications
    case myClutter
}

/// Source of truth for the "Customize Smart Care" preferences: which of the five
/// Smart Scan modules run, and — within the Cleanup (System Junk) module — which
/// `ScanCategory` sub-groups are included. Persisted in `UserDefaults` so the
/// choices survive relaunch.
///
/// Both selections default to "everything on", so a fresh install behaves exactly
/// like before this feature existed; narrowing the scan is opt-in. The
/// `UserDefaults` instance is injected so tests can use an isolated suite, the
/// same seam `ExclusionsStore` uses.
///
/// Semantics mirror the reference: disabling a module excludes its whole subtree,
/// so a disabled `.systemJunk` module suppresses every category regardless of the
/// per-category flags. The category flags only take effect when `.systemJunk` is
/// enabled; `SmartScanViewModel` ANDs the two at scan time.
@MainActor
@Observable
final class SmartScanSettingsStore {

    /// Tri-state of the Cleanup (System Junk) parent row in the settings tree.
    enum CheckState {
        /// Module enabled and every System Junk category included.
        case on
        /// Module disabled — the whole subtree is excluded.
        case off
        /// Module enabled but at least one category is excluded.
        case mixed
    }

    private enum Key {
        static let enabledModules = "smartScan.enabledModules"
        static let enabledJunkCategories = "smartScan.enabledJunkCategories"
    }

    /// The System Junk categories shown as the Cleanup module's sub-tree, in
    /// display order. `.largeFile` / `.oldFile` are excluded because they belong
    /// to the My Clutter module, not System Junk.
    static let junkCategories: [ScanCategory] = ScanCategory.allCases.filter {
        $0 != .largeFile && $0 != .oldFile
    }

    /// Modules currently included in Smart Scan. Defaults to all five.
    private(set) var enabledModules: Set<SmartScanModule>

    /// System Junk categories currently included. Defaults to all of
    /// `junkCategories`.
    private(set) var enabledJunkCategories: Set<ScanCategory>

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A missing key means "never customized" → default to everything on.
        // Reading via `array(forKey:)` and mapping raw values keeps unknown
        // strings (e.g. a category removed in a future build) from crashing.
        if let raw = defaults.array(forKey: Key.enabledModules) as? [String] {
            self.enabledModules = Set(raw.compactMap(SmartScanModule.init(rawValue:)))
        } else {
            self.enabledModules = Set(SmartScanModule.allCases)
        }
        if let raw = defaults.array(forKey: Key.enabledJunkCategories) as? [String] {
            self.enabledJunkCategories = Set(raw.compactMap(ScanCategory.init(rawValue:)))
                .intersection(Self.junkCategories)
        } else {
            self.enabledJunkCategories = Set(Self.junkCategories)
        }
    }

    // MARK: - Modules

    func isModuleEnabled(_ module: SmartScanModule) -> Bool {
        enabledModules.contains(module)
    }

    func setModule(_ module: SmartScanModule, enabled: Bool) {
        if enabled {
            enabledModules.insert(module)
        } else {
            enabledModules.remove(module)
        }
        persistModules()
    }

    // MARK: - System Junk categories

    func isJunkCategoryEnabled(_ category: ScanCategory) -> Bool {
        enabledJunkCategories.contains(category)
    }

    func setJunkCategory(_ category: ScanCategory, enabled: Bool) {
        if enabled {
            enabledJunkCategories.insert(category)
        } else {
            enabledJunkCategories.remove(category)
        }
        persistJunkCategories()
    }

    /// Tri-state for the Cleanup parent: `.off` when the module is disabled,
    /// `.on` when it is enabled and every category is included, `.mixed`
    /// otherwise.
    var junkCategoryState: CheckState {
        guard isModuleEnabled(.systemJunk) else { return .off }
        return enabledJunkCategories.count == Self.junkCategories.count ? .on : .mixed
    }

    // MARK: - Persistence

    private func persistModules() {
        defaults.set(enabledModules.map(\.rawValue), forKey: Key.enabledModules)
    }

    private func persistJunkCategories() {
        defaults.set(enabledJunkCategories.map(\.rawValue), forKey: Key.enabledJunkCategories)
    }
}
