// SmartScanSettingsStore.swift
// Observable settings for which Smart Scan care domains (and System Junk sub-categories) a scan includes — backed by UserDefaults, defaults to everything enabled.

import Foundation
import Observation

/// Source of truth for the "Customize Smart Care" preferences: which
/// `CareDomain`s run in Smart Scan, and — within the Cleanup domain — which
/// `ScanCategory` sub-groups are included. Persisted in `UserDefaults` so
/// the choices survive relaunch.
///
/// Domain states persist as a `[String: Bool]` dictionary where a *missing*
/// entry means enabled — so a domain added in a future build defaults on
/// even for installs that customized the older set. Earlier builds persisted
/// an enabled-modules *array* (absence meant disabled), which would have
/// silently switched new domains off; `init` migrates that format once,
/// preserving the user's exclusions while enabling the domains the legacy
/// build didn't know.
///
/// Semantics mirror the reference: disabling a domain excludes its whole
/// subtree, so a disabled Cleanup domain suppresses every category
/// regardless of the per-category flags. The category flags only take
/// effect when Cleanup is enabled; the scan configuration ANDs the two.
/// The `UserDefaults` instance is injected so tests use an isolated suite.
@MainActor
@Observable
final class SmartScanSettingsStore {

    /// Tri-state of the Cleanup parent row in the settings tree.
    enum CheckState {
        /// Domain enabled and every System Junk category included.
        case on
        /// Domain disabled — the whole subtree is excluded.
        case off
        /// Domain enabled but at least one category is excluded.
        case mixed
    }

    private enum Key {
        static let moduleStates = "smartScan.moduleStates"
        static let legacyEnabledModules = "smartScan.enabledModules"
        static let enabledJunkCategories = "smartScan.enabledJunkCategories"
        static let unitStates = "smartScan.unitStates"
    }

    /// The System Junk categories shown as the Cleanup domain's sub-tree, in
    /// display order. `.largeFile` / `.oldFile` are excluded because they
    /// belong to the My Clutter domain, not System Junk.
    static let junkCategories: [ScanCategory] = ScanCategory.allCases.filter {
        $0 != .largeFile && $0 != .oldFile
    }

    /// Explicitly-set domain states. A missing entry means enabled.
    private(set) var domainStates: [CareDomain: Bool]

    /// System Junk categories currently included. Defaults to all of
    /// `junkCategories`.
    private(set) var enabledJunkCategories: Set<ScanCategory>

    /// Explicitly-set per-unit (sub-scan) states. A missing entry means enabled,
    /// so a unit added in a future build defaults on even for installs that
    /// customized the older set — the same "missing means enabled" contract the
    /// domain states use.
    private(set) var unitStates: [CareScanUnit: Bool]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Key.moduleStates) {
            // Unknown keys and non-bool values are dropped: absence means
            // enabled, so corrupt data can only ever *enable*, never
            // silently switch a feature off.
            var states: [CareDomain: Bool] = [:]
            for (raw, value) in stored {
                guard let domain = CareDomain(rawValue: raw), let flag = value as? Bool else { continue }
                states[domain] = flag
            }
            self.domainStates = states
        } else if let legacy = defaults.array(forKey: Key.legacyEnabledModules) as? [String] {
            // One-time migration from the enabled-array format: a legacy
            // domain keeps its stored choice; domains the legacy build
            // didn't know (Browser Privacy) stay absent — enabled.
            let legacySet = Set(legacy)
            let legacyKnownDomains: [CareDomain] = [.systemJunk, .malware, .performance, .applications, .myClutter]
            var states: [CareDomain: Bool] = [:]
            for domain in legacyKnownDomains {
                states[domain] = legacySet.contains(domain.rawValue)
            }
            self.domainStates = states
        } else {
            self.domainStates = [:]
        }
        if let raw = defaults.array(forKey: Key.enabledJunkCategories) as? [String] {
            self.enabledJunkCategories = Set(raw.compactMap(ScanCategory.init(rawValue:)))
                .intersection(Self.junkCategories)
        } else {
            self.enabledJunkCategories = Set(Self.junkCategories)
        }
        if let stored = defaults.dictionary(forKey: Key.unitStates) {
            // Same discipline as the domain dictionary: unknown keys and
            // non-bool values are dropped so corrupt data can only ever enable.
            var states: [CareScanUnit: Bool] = [:]
            for (raw, value) in stored {
                guard let unit = CareScanUnit(rawValue: raw), let flag = value as? Bool else { continue }
                states[unit] = flag
            }
            self.unitStates = states
        } else {
            self.unitStates = [:]
        }
        // Persist the migrated (or freshly-parsed) dictionary so the legacy
        // key stops being authoritative from now on.
        if defaults.dictionary(forKey: Key.moduleStates) == nil,
           defaults.array(forKey: Key.legacyEnabledModules) != nil {
            persistDomains()
        }
    }

    // MARK: - Domains

    /// Domains currently included in Smart Scan.
    var enabledDomains: Set<CareDomain> {
        Set(CareDomain.allCases.filter { isDomainEnabled($0) })
    }

    func isDomainEnabled(_ domain: CareDomain) -> Bool {
        domainStates[domain] ?? true
    }

    func setDomain(_ domain: CareDomain, enabled: Bool) {
        domainStates[domain] = enabled
        persistDomains()
    }

    // MARK: - Units (per-feature sub-scans)

    /// The scan units the user hasn't switched off. A unit still only runs when
    /// its domain is also enabled — the scan configuration ANDs the two — so this
    /// set carries only the per-unit choice, not the domain gate.
    var enabledUnits: Set<CareScanUnit> {
        Set(CareScanUnit.allCases.filter { isUnitEnabled($0) })
    }

    func isUnitEnabled(_ unit: CareScanUnit) -> Bool {
        unitStates[unit] ?? true
    }

    func setUnit(_ unit: CareScanUnit, enabled: Bool) {
        unitStates[unit] = enabled
        persistUnits()
    }

    /// Tri-state for a multi-unit domain's parent row: `.off` when the domain is
    /// disabled, `.on` when it is enabled and every one of its units is on,
    /// `.mixed` when some units are switched off.
    func unitState(for domain: CareDomain) -> CheckState {
        guard isDomainEnabled(domain) else { return .off }
        let units = domain.units
        let on = units.filter { isUnitEnabled($0) }.count
        if on == units.count { return .on }
        if on == 0 { return .off }
        return .mixed
    }

    // MARK: - Restore defaults

    /// Resets Smart Care to a fresh-install profile: every care domain, System
    /// Junk category, and sub-scan unit enabled. Clearing the state dictionaries
    /// restores the "missing entry means enabled" default all at once.
    func restoreDefaults() {
        domainStates = [:]
        enabledJunkCategories = Set(Self.junkCategories)
        unitStates = [:]
        persistDomains()
        persistJunkCategories()
        persistUnits()
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

    /// Tri-state for the Cleanup parent: `.off` when the domain is disabled,
    /// `.on` when it is enabled and every category is included, `.mixed`
    /// otherwise.
    var junkCategoryState: CheckState {
        guard isDomainEnabled(.systemJunk) else { return .off }
        return enabledJunkCategories.count == Self.junkCategories.count ? .on : .mixed
    }

    // MARK: - Persistence

    private func persistDomains() {
        var stored: [String: Bool] = [:]
        for (domain, enabled) in domainStates {
            stored[domain.rawValue] = enabled
        }
        defaults.set(stored, forKey: Key.moduleStates)
    }

    private func persistJunkCategories() {
        defaults.set(enabledJunkCategories.map(\.rawValue), forKey: Key.enabledJunkCategories)
    }

    private func persistUnits() {
        var stored: [String: Bool] = [:]
        for (unit, enabled) in unitStates {
            stored[unit.rawValue] = enabled
        }
        defaults.set(stored, forKey: Key.unitStates)
    }
}
