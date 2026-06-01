// MaintenanceTaskRunnersTests.swift
// Verifies the privileged maintenance-task runners (DNS flush, Spotlight reindex, Time Machine thinning) each invoke their selector and bridge success/failure/dropped-reply correctly.

import XCTest
@testable import VaderCleaner

final class MaintenanceTaskRunnersTests: XCTestCase {

    // MARK: - DNS cache

    func test_dnsFlusher_invokesSelectorAndReturnsResult() async throws {
        let helper = RecordingHelper(replyError: nil)
        let runner = DNSCacheFlusher(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains("flushDNSCache"))
        XCTAssertFalse(output.isEmpty)
    }

    func test_dnsFlusher_throwsWhenHelperRepliesError() async {
        let helper = RecordingHelper(replyError: Boom())
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
            return DroppingHelper()
        })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    // MARK: - Spotlight

    func test_spotlightReindexer_invokesSelectorAndReturnsResult() async throws {
        let helper = RecordingHelper(replyError: nil)
        let runner = SpotlightReindexer(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains("reindexSpotlight"))
        XCTAssertFalse(output.isEmpty)
    }

    func test_spotlightReindexer_throwsWhenHelperRepliesError() async {
        let helper = RecordingHelper(replyError: Boom())
        let runner = SpotlightReindexer(helperProvider: { _ in helper })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    func test_spotlightReindexer_throwsWhenHelperUnavailable() async {
        let runner = SpotlightReindexer(helperProvider: { _ in nil })
        await XCTAssertThrowsErrorAsync(try await runner.run())
    }

    // MARK: - Time Machine

    func test_tmThinner_invokesSelectorAndReturnsResult() async throws {
        let helper = RecordingHelper(replyError: nil)
        let runner = TimeMachineSnapshotThinner(helperProvider: { _ in helper })

        let output = try await runner.run()

        XCTAssertTrue(helper.calledSelectors.contains("thinTimeMachineSnapshots"))
        XCTAssertFalse(output.isEmpty)
    }

    func test_tmThinner_throwsWhenHelperRepliesError() async {
        let helper = RecordingHelper(replyError: Boom())
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

/// Records which protocol selectors were invoked and replies with a configured
/// error. Replies success for the calls the runners under test don't make.
private final class RecordingHelper: NSObject, VaderCleanerHelperProtocol {
    private let replyError: Error?
    private(set) var calledSelectors: [String] = []

    init(replyError: Error?) { self.replyError = replyError }

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) { reply(nil) }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushDNSCache(reply: @escaping (Error?) -> Void) {
        calledSelectors.append("flushDNSCache")
        reply(replyError)
    }
    func reindexSpotlight(reply: @escaping (Error?) -> Void) {
        calledSelectors.append("reindexSpotlight")
        reply(replyError)
    }
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) {
        calledSelectors.append("thinTimeMachineSnapshots")
        reply(replyError)
    }
}

/// Drops every reply block — models a dead NSXPCConnection where the
/// connection-level error handler fires instead of the per-call reply.
private final class DroppingHelper: NSObject, VaderCleanerHelperProtocol {
    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {}
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {}
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) {}
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {}
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {}
    func flushDNSCache(reply: @escaping (Error?) -> Void) {}
    func reindexSpotlight(reply: @escaping (Error?) -> Void) {}
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) {}
}
