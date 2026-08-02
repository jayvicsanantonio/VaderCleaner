// UpdateSuppressionStore.swift
// Records the update versions the user has declined, so a skipped release stops being offered while a later one still surfaces.

import Foundation
import Observation

/// Immutable view of the skip records, safe to hand to the off-main
/// probe path. The store is main-actor isolated; a check runs in detached
/// tasks, so it takes a value rather than reaching back across actors.
struct UpdateSuppressionSnapshot: Sendable {

    /// Bundle ID → the highest version the user has declined.
    private let skippedVersions: [String: String]

    init(skippedVersions: [String: String] = [:]) {
        self.skippedVersions = skippedVersions
    }

    /// Whether `info` should be withheld.
    ///
    /// Only versions at or below the declined one are suppressed. A newer
    /// release resurfaces, which is what separates "skip this version"
    /// from "never tell me about this app" — without it the control would
    /// silently become a permanent mute and the user would stop hearing
    /// about security fixes.
    func suppresses(_ info: UpdateInfo) -> Bool {
        guard let skipped = skippedVersions[info.bundleID] else { return false }
        return VersionComparator.compare(info.latestVersion, skipped) != .orderedDescending
    }
}

/// Source of truth for declined updates, persisted in `UserDefaults` so
/// the choice survives relaunch — a skip that forgot itself would nag
/// again on next launch, which is the complaint it exists to answer.
///
/// The `UserDefaults` instance is injected so tests use an isolated suite.
@MainActor
@Observable
final class UpdateSuppressionStore {

    private enum Key {
        static let skippedVersions = "updater.skippedVersions"
    }

    /// Bundle ID → the highest version the user has declined.
    private(set) var skippedVersions: [String: String] = [:]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A malformed payload degrades to "nothing skipped". Suppressing
        // nothing is the safe direction: the user sees an update they
        // already declined, rather than missing one they never did.
        skippedVersions = defaults.dictionary(forKey: Key.skippedVersions) as? [String: String] ?? [:]
    }

    func suppresses(_ info: UpdateInfo) -> Bool {
        snapshot().suppresses(info)
    }

    func snapshot() -> UpdateSuppressionSnapshot {
        UpdateSuppressionSnapshot(skippedVersions: skippedVersions)
    }

    /// Records `info.latestVersion` as declined for its app.
    func skip(_ info: UpdateInfo) {
        skippedVersions[info.bundleID] = info.latestVersion
        persist()
    }

    func clearSkip(forBundleID bundleID: String) {
        guard skippedVersions.removeValue(forKey: bundleID) != nil else { return }
        persist()
    }

    /// Drops records the installed version has caught up to.
    ///
    /// Once the app is at or past the declined version the record
    /// describes nothing, and leaving it would silently mute a later
    /// reinstall at an older version.
    func pruneSkips(installedVersionsByBundleID: [String: String]) {
        let survivors = skippedVersions.filter { bundleID, skipped in
            guard let installed = installedVersionsByBundleID[bundleID] else { return true }
            return VersionComparator.compare(installed, skipped) == .orderedAscending
        }
        guard survivors.count != skippedVersions.count else { return }
        skippedVersions = survivors
        persist()
    }

    private func persist() {
        defaults.set(skippedVersions, forKey: Key.skippedVersions)
    }
}
