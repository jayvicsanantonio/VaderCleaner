// MaintenanceScriptRunnerTests.swift
// Verifies MaintenanceScriptRunner bridges the privileged runMaintenanceScripts XPC call and reports a result string.

import XCTest
@testable import VaderCleaner

final class MaintenanceScriptRunnerTests: XCTestCase {

    func test_run_returnsNonEmptyResultOnSuccess() async throws {
        let helper = SpyMaintenanceHelper(replyError: nil)
        let runner = MaintenanceScriptRunner(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.runCalled)
        XCTAssertFalse(output.isEmpty)
    }

    func test_run_throwsWhenHelperRepliesError() async {
        struct Boom: Error {}
        let helper = SpyMaintenanceHelper(replyError: Boom())
        let runner = MaintenanceScriptRunner(helperProvider: { _ in helper })

        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw")
        } catch {
            // Expected.
        }
    }

    func test_run_throwsWhenHelperUnavailable() async {
        let runner = MaintenanceScriptRunner(helperProvider: { _ in nil })
        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw when helper is unavailable")
        } catch {
            // Expected.
        }
    }

    /// The reply block is dropped (mirrors a dropped NSXPCConnection); the
    /// connection-level error handler must still resolve the await so the
    /// once-only continuation guarantee holds here as it does in RAMManager.
    func test_run_resolvesViaConnectionErrorHandlerWhenReplyDropped() async {
        struct Dropped: Error {}
        let runner = MaintenanceScriptRunner(helperProvider: { errorHandler in
            DispatchQueue.global().async { errorHandler(Dropped()) }
            return DroppingMaintenanceHelper()
        })

        do {
            _ = try await runner.run()
            XCTFail("Expected run() to surface the connection error")
        } catch {
            // Expected — did not hang.
        }
    }
}

private final class DroppingMaintenanceHelper: NSObject, VaderCleanerHelperProtocol {
    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {}
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {}
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) {}
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {}
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {}
    func flushDNSCache(reply: @escaping (Error?) -> Void) {}
    func reindexSpotlight(reply: @escaping (Error?) -> Void) {}
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) {}
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) {}
}

private final class SpyMaintenanceHelper: NSObject, VaderCleanerHelperProtocol {
    private let replyError: Error?
    private(set) var runCalled = false

    init(replyError: Error?) { self.replyError = replyError }

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) { reply(nil) }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {
        runCalled = true
        reply(replyError)
    }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushDNSCache(reply: @escaping (Error?) -> Void) { reply(nil) }
    func reindexSpotlight(reply: @escaping (Error?) -> Void) { reply(nil) }
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) { reply(nil) }
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) { reply([], [], nil) }
}
