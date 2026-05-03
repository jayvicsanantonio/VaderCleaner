// main.swift
// Entry point for VaderCleanerHelper — the privileged XPC daemon that performs root-level operations.

import Foundation

/// NSXPCListener delegate that vends a HelperService for each new XPC connection
/// and implements the privileged operations defined in VaderCleanerHelperProtocol.
final class HelperService: NSObject, NSXPCListenerDelegate, VaderCleanerHelperProtocol {

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: VaderCleanerHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: - VaderCleanerHelperProtocol

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        for path in paths {
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                reply(error)
                return
            }
        }
        reply(nil)
    }

    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {
        runProcess(
            launchPath: "/usr/sbin/periodic",
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
        runProcess(launchPath: "/usr/sbin/purge", arguments: [], reply: reply)
    }

    // MARK: - Private

    private func runProcess(
        launchPath: String,
        arguments: [String],
        reply: @escaping (Error?) -> Void
    ) {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                reply(NSError(
                    domain: "com.personal.VaderCleaner.helper",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "\(launchPath) exited with status \(process.terminationStatus)"]
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
RunLoop.current.run()
