// main.swift
// Entry point for VaderCleanerHelper — the privileged XPC daemon that performs root-level operations.

import Foundation

/// NSXPCListener delegate that vends a HelperService for each new XPC connection
/// and implements the privileged operations defined in VaderCleanerHelperProtocol.
final class HelperService: NSObject, NSXPCListenerDelegate, VaderCleanerHelperProtocol {
    private let deletionPolicy = HelperDeletionPolicy.production

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Reject any caller whose code-signing identity does not match the main app.
        // Without this check, any local process able to reach the mach service name could
        // invoke privileged operations (file deletion, /usr/sbin/purge, periodic scripts).
        // setCodeSigningRequirement is macOS 13+ — well within the macOS 14.0 deployment target.
        newConnection.setCodeSigningRequirement(kHelperClientCodeSigningRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: VaderCleanerHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: - VaderCleanerHelperProtocol

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {
        do {
            let firstError = try deletionPolicy.removeValidatedPaths(paths)
            reply(firstError)
        } catch {
            reply(error)
        }
    }

    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {
        runProcess(
            executable: "/usr/sbin/periodic",
            arguments: ["daily", "weekly", "monthly"],
            reply: reply
        )
    }

    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) {
        deleteFiles([path], reply: reply)
    }

    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {
        deleteFiles([path], reply: reply)
    }

    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {
        runProcess(executable: "/usr/sbin/purge", arguments: [], reply: reply)
    }

    func flushDNSCache(reply: @escaping (Error?) -> Void) {
        // Flushing the resolver cache is two steps: clear the directory-service
        // cache, then signal mDNSResponder to drop its own. Run them in sequence
        // and surface the first failure.
        runProcesses(
            commands: [
                (executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"]),
                (executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
            ],
            reply: reply
        )
    }

    func reindexSpotlight(reply: @escaping (Error?) -> Void) {
        runProcess(executable: "/usr/bin/mdutil", arguments: ["-E", "/"], reply: reply)
    }

    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) {
        // Ask Time Machine to reclaim up to 20 GiB of local snapshot space at
        // the highest urgency (4). macOS removes only as much as it safely can.
        runProcess(
            executable: "/usr/bin/tmutil",
            arguments: ["thinlocalsnapshots", "/", "21474836480", "4"],
            reply: reply
        )
    }

    // MARK: - Private

    /// Runs each command in order and replies with the first failure, or `nil`
    /// once all succeed. A non-zero exit or launch error short-circuits the rest.
    private func runProcesses(
        commands: [(executable: String, arguments: [String])],
        reply: @escaping (Error?) -> Void
    ) {
        for command in commands {
            var commandError: Error?
            runProcess(executable: command.executable, arguments: command.arguments) { error in
                commandError = error
            }
            if let commandError {
                reply(commandError)
                return
            }
        }
        reply(nil)
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        reply: @escaping (Error?) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                reply(NSError(
                    domain: "com.personal.VaderCleaner.helper",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)"]
                ))
                return
            }
            reply(nil)
        } catch {
            reply(error)
        }
    }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
