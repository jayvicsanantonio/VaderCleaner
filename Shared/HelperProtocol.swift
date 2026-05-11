// HelperProtocol.swift
// Shared @objc XPC protocol and mach service name used by both VaderCleaner and VaderCleanerHelper.

import Foundation

/// The mach service name used by both ends of the XPC connection.
/// Must match the launchd plist `MachServices` key, the helper's NSXPCListener,
/// and the app's NSXPCConnection. Defined here as the single source of truth.
let kHelperMachServiceName = "com.personal.VaderCleaner.helper"

enum HelperCodeSigningRequirements {
    static let appIdentifier = "com.personal.VaderCleaner"
    static let helperIdentifier = "com.personal.VaderCleaner.helper"

    /// Set to the Developer ID Team ID before distributing signed Release builds.
    private static let releaseTeamIdentifier: String? = nil

    static func requirement(identifier: String, teamIdentifier: String?) -> String {
        let identifierRequirement = "identifier \"\(identifier)\""
        guard let teamIdentifier = configuredTeamIdentifier(teamIdentifier) else {
            return identifierRequirement
        }
        return "\(identifierRequirement) and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func releaseRequirement(identifier: String, teamIdentifier: String? = releaseTeamIdentifier) -> String {
        requirement(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    private static func configuredTeamIdentifier(_ teamIdentifier: String?) -> String? {
        guard let teamIdentifier else { return nil }
        let trimmed = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "TEAMID" else { return nil }
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
}
