// MaintenanceScriptRunnerTests.swift
// Verifies MaintenanceScriptRunner bridges the privileged runMaintenanceScripts XPC call and reports a result string.

import XCTest
@testable import VaderCleanerCore

final class MaintenanceScriptRunnerTests: XCTestCase {

    func test_run_returnsNonEmptyResultOnSuccess() async throws {
        let helper = HelperProtocolSpy()
        let runner = MaintenanceScriptRunner(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains(.runMaintenanceScripts))
        XCTAssertFalse(output.isEmpty)
    }

    func test_run_throwsWhenHelperRepliesError() async {
        struct Boom: Error {}
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(Boom()), for: .runMaintenanceScripts)
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
            return HelperProtocolSpy(defaultReply: .drop)
        })

        do {
            _ = try await runner.run()
            XCTFail("Expected run() to surface the connection error")
        } catch {
            // Expected — did not hang.
        }
    }
}
