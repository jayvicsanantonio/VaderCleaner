// HelperProtocol.swift
// Shared @objc XPC protocol and mach service name used by both VaderCleaner and VaderCleanerHelper.

import Foundation

/// The mach service name used by both ends of the XPC connection.
/// Must match the launchd plist `MachServices` key, the helper's NSXPCListener,
/// and the app's NSXPCConnection. Defined here as the single source of truth.
let kHelperMachServiceName = "com.personal.VaderCleaner.helper"

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
