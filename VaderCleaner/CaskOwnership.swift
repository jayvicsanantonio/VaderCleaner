// CaskOwnership.swift
// Maps installed Homebrew casks to the .app bundles they own, so the Updater can tell which discovered apps Homebrew already manages and must not offer a direct download for.

import Foundation

/// Failure decoding `brew info --json=v2 --installed`. Distinct from a
/// `JSONSerialization` error so the caller can tell "brew emitted
/// something we don't understand" from "brew emitted invalid JSON".
enum BrewCaskOwnershipParseError: Error {
    case unexpectedRootShape
}

/// A single installed cask and the app bundles it installs.
///
/// `autoUpdates` mirrors the cask definition's `auto_updates` field: true
/// when the app keeps itself current, which is why `brew outdated` hides
/// it unless `--greedy` is passed.
struct CaskOwnership: Hashable, Sendable {
    let token: String
    let autoUpdates: Bool
    /// Bundle names the cask installs, e.g. `"Visual Studio Code.app"`.
    let appNames: [String]
    /// Absolute destinations, when the cask declares an explicit `target`.
    let appTargets: [URL]

    init(
        token: String,
        autoUpdates: Bool = false,
        appNames: [String] = [],
        appTargets: [URL] = []
    ) {
        self.token = token
        self.autoUpdates = autoUpdates
        self.appNames = appNames
        self.appTargets = appTargets
    }
}

/// Which discovered apps Homebrew installed.
///
/// A cask installs a real `.app` into `/Applications`, so app discovery
/// finds it and the Updater would happily offer it a direct download —
/// which overwrites a Caskroom-tracked install and leaves Homebrew's
/// manifest disagreeing with the disk. This map is what lets the Updater
/// recognise those apps and leave them to the Homebrew surface.
struct CaskOwnershipMap: Sendable {

    /// Caskroom tokens that `brew info` did not describe. Observed in
    /// practice as rename leftovers — `docker` lingering after the cask
    /// became `docker-desktop` — so they are reported for diagnosis
    /// rather than treated as evidence the inventory is untrustworthy.
    ///
    /// They deliberately do not claim ownership of anything. Suppressing
    /// an app on a token-name guess would hide an app that Homebrew can no
    /// longer upgrade either, which is how an app becomes invisible.
    let unresolvedTokens: [String]

    /// Lowercased bundle name → owning cask, for casks that install to the
    /// default location.
    private let byAppName: [String: CaskOwnership]
    /// Standardized absolute path → owning cask, for casks declaring an
    /// explicit `target`.
    private let byTarget: [String: CaskOwnership]

    init(casks: [CaskOwnership] = [], caskroomTokens: Set<String> = []) {
        var byAppName: [String: CaskOwnership] = [:]
        var byTarget: [String: CaskOwnership] = [:]
        for cask in casks {
            for name in cask.appNames {
                byAppName[name.lowercased()] = cask
            }
            for target in cask.appTargets {
                byTarget[target.standardizedFileURL.path] = cask
            }
        }
        self.byAppName = byAppName
        self.byTarget = byTarget
        let described = Set(casks.map(\.token))
        self.unresolvedTokens = caskroomTokens.subtracting(described).sorted()
    }

    /// The cask that installed `app`, or `nil` when Homebrew doesn't own it.
    ///
    /// A copy of a cask-installed app outside the default location still
    /// matches by name. The error is deliberate and one-sided: reading an
    /// unmanaged copy as managed only costs a missed update offer, while
    /// reading a managed app as unmanaged risks overwriting it.
    func owner(of app: AppInfo) -> CaskOwnership? {
        if let byPath = byTarget[app.bundleURL.standardizedFileURL.path] {
            return byPath
        }
        return byAppName[app.bundleURL.lastPathComponent.lowercased()]
    }
}
