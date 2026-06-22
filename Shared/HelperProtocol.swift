// HelperProtocol.swift
// Shared @objc XPC protocol and mach service name used by both VaderCleaner and VaderCleanerHelper.

import Foundation

/// The mach service name used by both ends of the XPC connection.
/// Must match the launchd plist `MachServices` key, the helper's NSXPCListener,
/// and the app's NSXPCConnection. Defined here as the single source of truth.
let kHelperMachServiceName = "com.personal.VaderCleaner.helper"

/// Absolute path of the macOS Document Versions store — the Versions/autosave
/// database of prior document revisions. It is owned by root and execute-only
/// (`d--x--x--x root wheel`), so it can only be *enumerated* by the privileged
/// helper running as root; a normal app process can't list it even with Full
/// Disk Access. Shared so the helper and the app agree on the one path the
/// `scanDocumentVersions` selector is allowed to read.
let kDocumentVersionsStorePath = "/System/Volumes/Data/.DocumentRevisions-V100"

enum HelperCodeSigningRequirements {
    static let appIdentifier = "com.personal.VaderCleaner"
    static let helperIdentifier = "com.personal.VaderCleaner.helper"

    /// Set to the Developer ID Team ID before distributing signed Release builds.
    ///
    /// BEFORE YOU DISTRIBUTE — security checklist (safe to ignore for a
    /// personal, locally-built, single-user app; each item only matters once
    /// the app leaves your own machine):
    ///
    ///   1. Set `releaseTeamIdentifier` to your Developer ID Team ID. Until
    ///      then a Release build authorizes the helper by bundle identifier
    ///      alone, which an ad-hoc binary can forge — local privilege
    ///      escalation to the root helper. Once set, the requirement becomes
    ///      `identifier "…" and anchor apple generic and certificate
    ///      leaf[subject.OU] = "<team>"`, which actually pins the connection.
    ///   2. Flip `ENABLE_HARDENED_RUNTIME` to YES in project.yml. It's
    ///      required for notarization, and the app's JIT / unsigned-memory
    ///      entitlements only take effect under the hardened runtime.
    ///   3. (Optional, stricter) Prefer the bundled ClamAV over the
    ///      user-writable Homebrew fallbacks (`/opt/homebrew/bin`,
    ///      `/usr/local/bin`) in `ClamAVDetector` / `DatabaseUpdater` so a
    ///      planted binary there can't be run in a Release build.
    private static let releaseTeamIdentifier: String? = nil

    #if !DEBUG
    #warning("Before distributing: set releaseTeamIdentifier to the Developer ID Team ID and enable the hardened runtime — see the checklist on releaseTeamIdentifier.")
    #endif

    static func requirement(identifier: String, teamIdentifier: String?) -> String {
        let identifierRequirement = "identifier \"\(identifier)\""
        guard let teamIdentifier = configuredTeamIdentifier(teamIdentifier) else {
            return identifierRequirement
        }
        // `anchor apple generic` is required, not optional: a bare
        // `certificate leaf[subject.OU] = "<team>"` is satisfied by any
        // self-signed certificate whose leaf simply sets that OU — and the
        // Team ID is public, so an attacker can forge it. Anchoring to
        // Apple's CA means only an Apple-issued (Developer ID / Development)
        // certificate carrying that team can pass, which is what actually
        // pins the connection's identity.
        return "\(identifierRequirement) and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func releaseRequirement(identifier: String, teamIdentifier: String? = releaseTeamIdentifier) -> String {
        requirement(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    private static func configuredTeamIdentifier(_ teamIdentifier: String?) -> String? {
        guard let teamIdentifier else { return nil }
        let trimmed = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("TEAMID") != .orderedSame else { return nil }
        return trimmed
    }

    #if DEBUG
    static let client = requirement(identifier: appIdentifier, teamIdentifier: nil)
    static let server = requirement(identifier: helperIdentifier, teamIdentifier: nil)
    #else
    static let client = releaseRequirement(identifier: appIdentifier)
    static let server = releaseRequirement(identifier: helperIdentifier)
    #endif
}

/// Code-signing requirement applied by the helper to incoming XPC connections.
/// Release builds include the Developer ID Team ID when configured; Debug and
/// local/ad-hoc builds allow identifier-only signing.
let kHelperClientCodeSigningRequirement = HelperCodeSigningRequirements.client

/// Code-signing requirement applied by the app to the helper connection — the
/// symmetric check that protects the app from a substituted helper binary.
let kHelperServerCodeSigningRequirement = HelperCodeSigningRequirements.server

/// XPC protocol implemented by VaderCleanerHelper and consumed by the main app.
///
/// All methods are reply-block based — NSXPCConnection requires @objc protocols
/// and the standard async pattern is `(reply: @escaping (Error?) -> Void)`.
/// Selectors are declared explicitly with @objc(...) so that runtime checks and
/// the helper's listener delegate match exactly without depending on Swift's
/// implicit selector mangling rules.
@objc(VaderCleanerHelperProtocol)
protocol VaderCleanerHelperProtocol {

    /// Removes the files at the given absolute paths.
    /// Reports the first error encountered (if any) via the reply block.
    @objc(deleteFiles:reply:)
    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void)

    /// Runs the standard system maintenance scripts: `periodic daily weekly monthly`.
    @objc(runMaintenanceScriptsWithReply:)
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void)

    /// Removes the file at the given login-item path (typically a launch agent plist).
    @objc(removeLoginItemAtPath:reply:)
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void)

    /// Removes the launch agent plist at the given path.
    @objc(removeLaunchAgentAtPath:reply:)
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void)

    /// Frees inactive memory by invoking the system `purge` command.
    @objc(flushInactiveMemoryWithReply:)
    func flushInactiveMemory(reply: @escaping (Error?) -> Void)

    /// Flushes the DNS resolver cache (`dscacheutil -flushcache` followed by
    /// `killall -HUP mDNSResponder`).
    @objc(flushDNSCacheWithReply:)
    func flushDNSCache(reply: @escaping (Error?) -> Void)

    /// Erases and rebuilds the Spotlight index for the boot volume
    /// (`mdutil -E /`).
    @objc(reindexSpotlightWithReply:)
    func reindexSpotlight(reply: @escaping (Error?) -> Void)

    /// Thins local Time Machine snapshots on the boot volume
    /// (`tmutil thinlocalsnapshots / <bytes> 4`).
    @objc(thinTimeMachineSnapshotsWithReply:)
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void)

    /// Recursively enumerates the regular files in the root-owned Document
    /// Versions store (`kDocumentVersionsStorePath`), which the app can't list
    /// itself. Replies with parallel arrays of absolute file paths and their
    /// byte sizes, plus the first error encountered (if any). The path is fixed
    /// helper-side — there is intentionally no caller-supplied path argument, so
    /// this never becomes a general "enumerate any directory as root" capability.
    @objc(scanDocumentVersionsWithReply:)
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void)
}
