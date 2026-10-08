// BrewPackage.swift
// Value types describing Homebrew packages, outdated entries, and uninstall confirmations surfaced by the Homebrew Manager.

import Foundation

/// Whether a Homebrew package is a formula (CLI tool / library) or a cask
/// (GUI app / binary). Names are unique only *within* a kind — a formula and
/// a cask can share a name — so `id` composition folds the kind in.
public enum BrewPackageKind: String, Sendable, CaseIterable {
    case formula
    case cask
}

/// A single installed Homebrew package plus the metadata the manager needs to
/// list it and decide what to update or remove.
///
/// On-disk size is optional and off the critical path: Homebrew does not report
/// per-package size in `list`/`outdated`, so `sizeBytes` is filled lazily (or
/// left `nil`). The reclaim figure that drives the cleanup flow comes from
/// `brew cleanup -n`, not from summing package sizes.
public struct BrewPackage: Identifiable, Hashable, Sendable {
    public let name: String
    public let kind: BrewPackageKind
    public let installedVersions: [String]
    /// `true` when this formula was installed on request and nothing else
    /// depends on it (`brew leaves`) — safe to remove without orphaning a
    /// dependent. Casks are always leaves in this sense.
    public let isLeaf: Bool
    var sizeBytes: Int64?

    init(
        name: String,
        kind: BrewPackageKind,
        installedVersions: [String],
        isLeaf: Bool,
        sizeBytes: Int64? = nil
    ) {
        self.name = name
        self.kind = kind
        self.installedVersions = installedVersions
        self.isLeaf = isLeaf
        self.sizeBytes = sizeBytes
    }

    /// Keys off name *and* kind because a formula and a cask can share a name;
    /// keying off name alone would collapse them into one list row.
    public var id: String { name + "|" + kind.rawValue }
}

/// A package with a newer version available, parsed from `brew outdated
/// --json=v2`. `isPinned` gates it out of "upgrade all" — a pinned formula is
/// deliberately held back and must never be swept up by a bulk upgrade.
public struct BrewOutdatedItem: Identifiable, Hashable, Sendable {
    public let name: String
    public let kind: BrewPackageKind
    public let installedVersion: String
    public let candidateVersion: String
    public let isPinned: Bool

    public var id: String { name + "|" + kind.rawValue }
}

/// The result of the pre-uninstall reverse-dependency check. `dependents` maps
/// each target package name to the installed packages that depend on it (from
/// `brew uses --installed`); a non-empty list means removing the target would
/// break those dependents, so the manager must confirm before proceeding.
public struct UninstallConfirmation: Equatable, Sendable {
    public let targets: [BrewPackage]
    public let dependents: [String: [String]]

    /// `true` when at least one target has an installed dependent — the signal
    /// the view uses to require an explicit confirmation rather than removing
    /// silently.
    public var hasBlockingDependents: Bool {
        dependents.values.contains { !$0.isEmpty }
    }
}

/// Which packages an upgrade action targets. `.all` upgrades everything
/// outdated except pinned formulae; `.some` upgrades exactly the named
/// packages.
public enum UpgradeSelection: Equatable, Sendable {
    case all
    case some([String])
}
