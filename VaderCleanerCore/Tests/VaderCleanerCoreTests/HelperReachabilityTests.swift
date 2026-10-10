// HelperReachabilityTests.swift
// Verifies the helper reachability probe answers "reachable" only when the helper actually replies, and treats a dead connection as unreachable without side effects.

import XCTest
@testable import VaderCleanerCore

final class HelperReachabilityTests: XCTestCase {

    func test_probe_isReachableWhenTheHelperReplies() async {
        let helper = HelperProtocolSpy()
        let probe = HelperReachability(helperProvider: { _ in helper })

        let reachable = await probe.probe()

        XCTAssertTrue(reachable)
    }

    /// The probe must not delete anything — it asks for an empty batch, which
    /// the helper's deletion policy treats as a no-op.
    func test_probe_asksForAnEmptyDeletion() async {
        let helper = HelperProtocolSpy()
        let probe = HelperReachability(helperProvider: { _ in helper })

        _ = await probe.probe()

        XCTAssertEqual(helper.deleteFilesBatches, [[]], "the probe must never name a path")
    }

    func test_probe_isUnreachableWhenTheHelperIsUnavailable() async {
        let probe = HelperReachability(helperProvider: { _ in nil })

        let reachable = await probe.probe()

        XCTAssertFalse(reachable)
    }

    /// The exact failure this exists to catch: a stale registration where the
    /// mach service lookup fails, which `NSXPCConnection` reports as Cocoa 4099.
    func test_probe_isUnreachableOnAConnectionFailure() async {
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(NSError(domain: NSCocoaErrorDomain, code: 4099)), for: .deleteFiles)
        let probe = HelperReachability(helperProvider: { _ in helper })

        let reachable = await probe.probe()

        XCTAssertFalse(reachable)
    }

    /// A dropped reply block (dead connection) resolves through the
    /// connection-level error handler rather than hanging the probe.
    func test_probe_isUnreachableWhenTheReplyIsDropped() async {
        let probe = HelperReachability(helperProvider: { errorHandler in
            DispatchQueue.global().async {
                errorHandler(NSError(domain: NSCocoaErrorDomain, code: 4097))
            }
            return HelperProtocolSpy(defaultReply: .drop)
        })

        let reachable = await probe.probe()

        XCTAssertFalse(reachable)
    }

    /// Reachability means "the helper answered", not "the work succeeded" — a
    /// substantive error still proves the connection is alive.
    func test_probe_isReachableWhenTheHelperAnswersWithItsOwnError() async {
        let helper = HelperProtocolSpy()
        helper.setReply(.failure(NSError(domain: "policy", code: 7)), for: .deleteFiles)
        let probe = HelperReachability(helperProvider: { _ in helper })

        let reachable = await probe.probe()

        XCTAssertTrue(reachable)
    }
}
