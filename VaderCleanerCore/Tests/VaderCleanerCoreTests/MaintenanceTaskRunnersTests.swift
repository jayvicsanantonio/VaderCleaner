// MaintenanceTaskRunnersTests.swift
// Verifies the privileged maintenance-task runners (DNS flush, Spotlight reindex, Time Machine thinning) each invoke their selector and bridge success/failure/dropped-reply correctly.

import XCTest
@testable import VaderCleanerCore

final class MaintenanceTaskRunnersTests: XCTestCase {

    // MARK: - DNS cache

    func test_dnsFlusher_invokesSelectorAndReturnsResult() async throws {
        let helper = HelperProtocolSpy()
        let runner = DNSCacheFlusher(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains(.flushDNSCache))
        XCTAssertFalse(output.isEmpty)
    }

    func test_dnsFlusher_throwsWhenHelperRepliesError() async {
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(Boom()), for: .flushDNSCache)
        let runner = DNSCacheFlusher(helperProvider: { _ in helper })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    func test_dnsFlusher_throwsWhenHelperUnavailable() async {
        let runner = DNSCacheFlusher(helperProvider: { _ in nil })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    /// The reply block is dropped (mirrors a dropped NSXPCConnection); the
    /// connection-level error handler must still resolve the await so the
    /// shared once-only continuation guarantee holds.
    func test_dnsFlusher_resolvesViaConnectionErrorHandlerWhenReplyDropped() async {
        let runner = DNSCacheFlusher(helperProvider: { errorHandler in
            DispatchQueue.global().async { errorHandler(Boom()) }
            return HelperProtocolSpy(defaultReply: .drop)
        })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    // MARK: - Spotlight

    func test_spotlightReindexer_invokesSelectorAndReturnsResult() async throws {
        let helper = HelperProtocolSpy()
        let runner = SpotlightReindexer(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains(.reindexSpotlight))
        XCTAssertFalse(output.isEmpty)
    }

    func test_spotlightReindexer_throwsWhenHelperRepliesError() async {
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(Boom()), for: .reindexSpotlight)
        let runner = SpotlightReindexer(helperProvider: { _ in helper })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    func test_spotlightReindexer_throwsWhenHelperUnavailable() async {
        let runner = SpotlightReindexer(helperProvider: { _ in nil })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    // MARK: - Time Machine

    func test_tmThinner_invokesSelectorAndReturnsResult() async throws {
        let helper = HelperProtocolSpy()
        let runner = TimeMachineSnapshotThinner(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains(.thinTimeMachineSnapshots))
        XCTAssertFalse(output.isEmpty)
    }

    func test_tmThinner_throwsWhenHelperRepliesError() async {
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(Boom()), for: .thinTimeMachineSnapshots)
        let runner = TimeMachineSnapshotThinner(helperProvider: { _ in helper })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    func test_tmThinner_throwsWhenHelperUnavailable() async {
        let runner = TimeMachineSnapshotThinner(helperProvider: { _ in nil })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }
}

private struct Boom: Error {}

/// Async XCTAssertThrowsError — XCTest's built-in version is synchronous.
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        // Expected.
    }
}
