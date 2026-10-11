// HelperProtocol.swift
// Shared @objc XPC protocol and mach service name used by both VaderCleaner and VaderCleanerHelper.

import Foundation
import Security

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

    /// An explicit Team ID both ends pin each other to, whatever the running
    /// build happens to be signed with.
    ///
    /// Optional: without it each end pins its peer to the team it is itself
    /// signed by (see `peerRequirement`), which already holds for Apple
    /// Development and Developer ID builds alike.
    ///
    /// BEFORE YOU DISTRIBUTE — security checklist (safe to ignore for a
    /// personal, locally-built, single-user app; each item only matters once
    /// the app leaves your own machine):
    ///
    ///   1. Set `releaseTeamIdentifier` to your Developer ID Team ID. Until
    ///      then a build that ends up ad-hoc signed authorizes its peer by
    ///      bundle identifier alone, which an ad-hoc binary can forge — local
    ///      privilege escalation to the root helper. Once set, the
    ///      requirement is always `identifier "…" and anchor apple generic
    ///      and certificate leaf[subject.OU] = "<team>"`, so a mis-signed
    ///      build fails closed instead.
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

    /// How the running process is itself signed, which decides what it can
    /// demand of its peer.
    enum OwnSigning: Equatable {
        /// Signed with an Apple-issued certificate belonging to this team.
        case team(String)
        /// Signed without an Apple-issued certificate — ad-hoc, as on CI and
        /// unsigned local builds — so there is no team to pin.
        case adHoc
        /// The signature couldn't be read, or the one on disk no longer
        /// matches the code that is running.
        case unverified
    }

    static func requirement(identifier: String, teamIdentifier: String?) -> String {
        let identifierRequirement = "identifier \"\(identifier)\""
        guard let teamIdentifier = configuredTeamIdentifier(teamIdentifier) else {
            return identifierRequirement
        }
        return "\(identifierRequirement) and \(teamPin(teamIdentifier))"
    }

    /// The requirement a peer signed as `identifier` must satisfy.
    ///
    /// Pinned to `overrideTeamIdentifier` when one is configured, and
    /// otherwise to the team this process is itself signed by: the app and
    /// the helper are built and signed together, so a genuine peer always
    /// shares it, while an ad-hoc binary that merely claims the identifier
    /// can't. Only an ad-hoc process falls back to the identifier alone,
    /// having no team to pin; one that can't verify its own signature
    /// accepts no peer at all.
    static func peerRequirement(
        identifier: String,
        overrideTeamIdentifier: String? = releaseTeamIdentifier,
        ownSigning: () -> OwnSigning = runningProcessSigning
    ) -> String {
        if let overrideTeamIdentifier = configuredTeamIdentifier(overrideTeamIdentifier) {
            return requirement(identifier: identifier, teamIdentifier: overrideTeamIdentifier)
        }
        switch ownSigning() {
        case .team(let teamIdentifier):
            return requirement(identifier: identifier, teamIdentifier: teamIdentifier)
        case .adHoc:
            return requirement(identifier: identifier, teamIdentifier: nil)
        case .unverified:
            return "never"
        }
    }

    /// Reads how the running process is signed.
    ///
    /// The Team ID comes from the signature on disk, and a file on disk can
    /// be swapped out from under a process that is already running — the
    /// helper runs from inside the app bundle, which is often somewhere the
    /// user can write. Read naively, a swapped-in binary signed with someone
    /// else's team, or ad-hoc, would steer the pin to that team or down to
    /// the identifier alone. So the reading only counts once the running
    /// code is confirmed to match it: dynamic validation checks the code
    /// the kernel launched against what is on disk, so a swap fails it.
    static func runningProcessSigning() -> OwnSigning {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unverified }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return .unverified
        }

        let teamIdentifier = signingTeamIdentifier(of: staticCode)
        // The value is spliced into a requirement string, and a crafted
        // signature can carry any text there — so anything but a Team ID's
        // ten uppercase letters and digits is refused rather than parsed.
        if let teamIdentifier, !isWellFormedTeamIdentifier(teamIdentifier) { return .unverified }
        // An ad-hoc reading has to be confirmed too, as the absence of an
        // Apple-issued certificate — otherwise a team-signed process that
        // read a swapped-in ad-hoc file would still pass.
        let confirmation = teamIdentifier.map(teamPin) ?? "! anchor apple generic"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(confirmation as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            return .unverified
        }
        return teamIdentifier.map(OwnSigning.team) ?? .adHoc
    }

    /// The Team ID recorded in `staticCode`'s signature, or nil when it
    /// carries none.
    static func signingTeamIdentifier(of staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether `candidate` has the shape of an Apple Team ID: exactly ten
    /// ASCII uppercase letters and digits.
    static func isWellFormedTeamIdentifier(_ candidate: String) -> Bool {
        candidate.count == 10 && candidate.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    private static func teamPin(_ teamIdentifier: String) -> String {
        // `anchor apple generic` is required, not optional: a bare
        // `certificate leaf[subject.OU] = "<team>"` is satisfied by any
        // self-signed certificate whose leaf simply sets that OU — and the
        // Team ID is public, so an attacker can forge it. Anchoring to
        // Apple's CA means only an Apple-issued (Developer ID / Development)
        // certificate carrying that team can pass, which is what actually
        // pins the connection's identity.
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func configuredTeamIdentifier(_ teamIdentifier: String?) -> String? {
        guard let teamIdentifier else { return nil }
        let trimmed = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("TEAMID") != .orderedSame else { return nil }
        return trimmed
    }

    static let client = peerRequirement(identifier: appIdentifier)
    static let server = peerRequirement(identifier: helperIdentifier)
}

/// Code-signing requirement applied by the helper to incoming XPC connections:
/// the app's identifier, pinned to the team the helper itself is signed with.
/// Identifier-only only when the helper is ad-hoc signed; see `peerRequirement`.
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
public protocol VaderCleanerHelperProtocol {

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
