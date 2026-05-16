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
}
