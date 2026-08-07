// main.swift
// Entry point for VaderCleanerHelper — the privileged XPC daemon that performs root-level operations.

import Foundation

/// NSXPCListener delegate that vends a HelperService for each new XPC connection
/// and implements the privileged operations defined in VaderCleanerHelperProtocol.
final class HelperService: NSObject, NSXPCListenerDelegate, VaderCleanerHelperProtocol {
    private let deletionPolicy = HelperDeletionPolicy.production
    private let documentVersionsScan = DocumentVersionsStoreScan()

    /// Where the actual work runs, off the queue XPC delivers calls on.
    ///
    /// Every operation here is slow by nature — `mdutil -E /` reindexes the
    /// boot volume, a cache deletion walks a directory tree — and the app
    /// talks to this helper over one shared connection, so doing the work on
    /// the delivery queue makes every privileged call wait behind whichever
    /// one happens to be slowest.
    ///
    /// Concurrent rather than serial: these are independent system commands,
    /// and serialising them would just move the head-of-line blocking one
    /// layer down instead of removing it.
    private let workQueue = DispatchQueue(
        label: "com.personal.VaderCleaner.helper.work",
        attributes: .concurrent
    )

    /// Carries an XPC reply block onto `workQueue`.
    ///
    /// `@unchecked Sendable`, backed by NSXPCConnection's own contract: a
    /// reply block is safe to invoke from any thread and is invoked exactly
    /// once. Swift can't see that through an `@objc` protocol's block
    /// parameter, and annotating the protocol's blocks instead is not an
    /// option — it would change the generated selectors the helper, the app,
    /// and every test spy agree on.
    private struct XPCReply<Block>: @unchecked Sendable {
        let send: Block

        init(_ send: Block) { self.send = send }
    }

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
        let policy = deletionPolicy
        let reply = XPCReply(reply)
        workQueue.async {
            do {
                let firstError = try policy.removeValidatedPaths(paths)
                reply.send(firstError)
            } catch {
                reply.send(error)
            }
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

    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) {
        // The path is fixed (not caller-supplied) so this can only ever read the
        // Document Versions store, never an arbitrary directory as root.
        let root = URL(fileURLWithPath: kDocumentVersionsStorePath, isDirectory: true)
        let scan = documentVersionsScan
        let reply = XPCReply(reply)
        workQueue.async {
            guard let entries = scan.entries(at: root) else {
                reply.send([], [], NSError(
                    domain: "com.personal.VaderCleaner.helper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not open \(root.path)"]
                ))
                return
            }
            reply.send(entries.paths, entries.sizes, nil)
        }
    }

    // MARK: - Private

    /// Runs each command in order and replies with the first failure, or `nil`
    /// once all succeed. A non-zero exit or launch error short-circuits the rest.
    ///
    /// The sequencing works because `execute` is synchronous: it returns only
    /// once its command has exited, so the loop below really does run the
    /// commands one after another. What moved off the XPC delivery queue is
    /// the whole loop, not each command inside it.
    private func runProcesses(
        commands: [(executable: String, arguments: [String])],
        reply: @escaping (Error?) -> Void
    ) {
        let reply = XPCReply(reply)
        workQueue.async {
            for command in commands {
                if let error = Self.execute(executable: command.executable,
                                            arguments: command.arguments) {
                    reply.send(error)
                    return
                }
            }
            reply.send(nil)
        }
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        reply: @escaping (Error?) -> Void
    ) {
        let reply = XPCReply(reply)
        workQueue.async {
            reply.send(Self.execute(executable: executable, arguments: arguments))
        }
    }

    /// Runs one command to completion and returns its failure, if any.
    ///
    /// Synchronous on purpose: callers have already hopped onto `workQueue`,
    /// and `runProcesses` depends on this returning only once the command is
    /// actually done.
    private static func execute(executable: String, arguments: [String]) -> Error? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return NSError(
                    domain: "com.personal.VaderCleaner.helper",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)"]
                )
            }
            return nil
        } catch {
            return error
        }
    }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
