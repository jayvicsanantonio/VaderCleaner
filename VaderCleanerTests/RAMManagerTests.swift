// RAMManagerTests.swift
// Verifies RAMManager bridges the privileged flushInactiveMemory XPC call and never hangs when the connection drops.

import XCTest
@testable import VaderCleaner

final class RAMManagerTests: XCTestCase {

    func test_flush_invokesHelperAndSucceeds() async throws {
        let helper = SpyFlushHelper(replyError: nil)
        let manager = RAMManager(helperProvider: { _ in helper })

        try await manager.flush()

        XCTAssertTrue(helper.flushCalled)
    }

    func test_flush_throwsWhenHelperRepliesError() async {
        struct Boom: Error {}
        let helper = SpyFlushHelper(replyError: Boom())
        let manager = RAMManager(helperProvider: { _ in helper })

        do {
            try await manager.flush()
            XCTFail("Expected flush() to throw")
        } catch {
            // Expected.
        }
    }

    func test_flush_throwsWhenHelperUnavailable() async {
        let manager = RAMManager(helperProvider: { _ in nil })
        do {
            try await manager.flush()
            XCTFail("Expected flush() to throw when helper is unavailable")
        } catch {
            // Expected.
        }
    }

    /// The reply block is dropped (mirrors a dropped NSXPCConnection); the
    /// connection-level error handler must still resolve the await.
    func test_flush_resolvesViaConnectionErrorHandlerWhenReplyDropped() async {
        struct Dropped: Error {}
        let manager = RAMManager(helperProvider: { errorHandler in
            DispatchQueue.global().async { errorHandler(Dropped()) }
            return DroppingFlushHelper()
        })

        do {
            try await manager.flush()
            XCTFail("Expected flush() to surface the connection error")
        } catch {
            // Expected — did not hang.
        }
    }
}

private final class SpyFlushHelper: NSObject, VaderCleanerHelperProtocol {
    private let replyError: Error?
    private(set) var flushCalled = false

    init(replyError: Error?) { self.replyError = replyError }

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) { reply(nil) }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {
        flushCalled = true
        reply(replyError)
    }
}

private final class DroppingFlushHelper: NSObject, VaderCleanerHelperProtocol {
    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {}
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {}
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) {}
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {}
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {}
}
