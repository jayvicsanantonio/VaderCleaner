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
        let fileManager = FileManager.default
        do {
            let firstError = try deletionPolicy.removeValidatedPaths(paths) { url in
                try fileManager.removeItem(at: url)
            }
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

    // MARK: - Private

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
