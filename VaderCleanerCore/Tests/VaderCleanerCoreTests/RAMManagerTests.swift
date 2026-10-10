// RAMManagerTests.swift
// Verifies RAMManager bridges the privileged flushInactiveMemory XPC call and never hangs when the connection drops.

import XCTest
@testable import VaderCleanerCore

final class RAMManagerTests: XCTestCase {

    func test_flush_invokesHelperAndSucceeds() async throws {
        let helper = HelperProtocolSpy()
        let manager = RAMManager(helperProvider: { _ in helper })

        try await manager.flush()

        XCTAssertTrue(helper.calledSelectors.contains(.flushInactiveMemory))
    }

    func test_flush_throwsWhenHelperRepliesError() async {
        struct Boom: Error {}
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(Boom()), for: .flushInactiveMemory)
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
            return HelperProtocolSpy(defaultReply: .drop)
        })

        do {
            try await manager.flush()
            XCTFail("Expected flush() to surface the connection error")
        } catch {
            // Expected — did not hang.
        }
    }
}
