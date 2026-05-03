// HelperConnectionManager.swift
// Singleton that owns the NSXPCConnection to VaderCleanerHelper and exposes a typed proxy.

import Foundation
import os.log

/// Manages the lifecycle of the privileged XPC connection to VaderCleanerHelper.
///
/// MANUAL CODESIGN STEP (required for the helper daemon to actually run):
///
///     codesign --force --sign - --identifier com.personal.VaderCleaner.helper \
///       "$BUILT_PRODUCTS_DIR/VaderCleaner.app/Contents/MacOS/VaderCleanerHelper"
///     codesign --force --sign - "$BUILT_PRODUCTS_DIR/VaderCleaner.app"
///
/// SMAppService.daemon().register() throws errSecCSUnsigned without ad-hoc signatures.
/// Failures are logged via os_log and do not crash the app — the architecture lives
/// regardless, but XPC calls will return connection errors until signing is in place.
final class HelperConnectionManager {

    static let shared = HelperConnectionManager()

    private let log = OSLog(subsystem: "com.personal.VaderCleaner", category: "HelperConnection")
    private var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "com.personal.VaderCleaner.helper-connection")

    private init() {}

    /// Returns the active NSXPCConnection, lazily constructing it on first use.
    /// Idempotent — subsequent calls return the same connection until invalidate() is called
    /// or the remote process invalidates the connection.
    @discardableResult
    func connect() -> NSXPCConnection {
        queue.sync {
            if let existing = connection {
                return existing
            }
            let new = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: VaderCleanerHelperProtocol.self)
            // Reject any helper whose code-signing identity does not match — protects
            // the app from a substituted/swapped binary at the same mach service name.
            try? new.setCodeSigningRequirement(kHelperServerCodeSigningRequirement)
            // Capture the connection's identity in the handler. If invalidate() runs
            // and a new connect() races ahead before the stale handler fires, the
            // identity check below prevents the stale handler from clearing the new
            // connection. queue.async (not sync) avoids re-entrancy if the XPC runtime
            // dispatches the handler synchronously while invalidate() is mid-flight.
            new.invalidationHandler = { [weak self, weak new] in
                guard let self, let conn = new else { return }
                os_log("Helper XPC connection invalidated", log: self.log, type: .info)
                self.queue.async {
                    if self.connection === conn { self.connection = nil }
                }
            }
            new.interruptionHandler = { [weak self, weak new] in
                guard let self, let conn = new else { return }
                os_log("Helper XPC connection interrupted; will reconnect on next use",
                       log: self.log, type: .info)
                self.queue.async {
                    if self.connection === conn { self.connection = nil }
                }
            }
            new.resume()
            connection = new
            return new
        }
    }

    /// Returns a synchronous proxy to the helper. The errorHandler is invoked when
    /// the underlying XPC call fails (e.g. when the daemon is not registered).
    func helper(errorHandler: @escaping (Error) -> Void) -> VaderCleanerHelperProtocol? {
        let proxy = connect().remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        }
        return proxy as? VaderCleanerHelperProtocol
    }

    /// Tears down the cached connection. Subsequent connect() calls will build a new one.
    func invalidate() {
        queue.sync {
            connection?.invalidate()
            connection = nil
        }
    }

}
