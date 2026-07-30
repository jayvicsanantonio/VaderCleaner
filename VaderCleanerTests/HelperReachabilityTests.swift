// HelperReachabilityTests.swift
// Verifies the helper reachability probe answers "reachable" only when the helper actually replies, and treats a dead connection as unreachable without side effects.

import XCTest
@testable import VaderCleaner

final class HelperReachabilityTests: XCTestCase {

    func test_probe_isReachableWhenTheHelperReplies() async {
        let helper = RecordingHelper(replyError: nil)
        let probe = HelperReachability(helperProvider: { _ in helper })

        let reachable = await probe.probe()

        XCTAssertTrue(reachable)
    }

    /// The probe must not delete anything — it asks for an empty batch, which
    /// the helper's deletion policy treats as a no-op.
    func test_probe_asksForAnEmptyDeletion() async {
        let helper = RecordingHelper(replyError: nil)
        let probe = HelperReachability(helperProvider: { _ in helper })

        _ = await probe.probe()

        XCTAssertEqual(helper.deletionRequests, [[]], "the probe must never name a path")
    }

    func test_probe_isUnreachableWhenTheHelperIsUnavailable() async {
        let probe = HelperReachability(helperProvider: { _ in nil })

        let reachable = await probe.probe()

        XCTAssertFalse(reachable)
    }

    /// The exact failure this exists to catch: a stale registration where the
    /// mach service lookup fails, which `NSXPCConnection` reports as Cocoa 4099.
    func test_probe_isUnreachableOnAConnectionFailure() async {
        let probe = HelperReachability(helperProvider: { _ in
            RecordingHelper(replyError: NSError(domain: NSCocoaErrorDomain, code: 4099))
        })

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
            return DroppingHelper()
        })

        let reachable = await probe.probe()

        XCTAssertFalse(reachable)
    }

    /// Reachability means "the helper answered", not "the work succeeded" — a
    /// substantive error still proves the connection is alive.
    func test_probe_isReachableWhenTheHelperAnswersWithItsOwnError() async {
        let probe = HelperReachability(helperProvider: { _ in
            RecordingHelper(replyError: NSError(domain: "policy", code: 7))
        })

        let reachable = await probe.probe()

        XCTAssertTrue(reachable)
    }
}

/// Records the deletion batches it was asked for and replies with a configured
/// error. `@unchecked Sendable`: a test spy written by the helper call and read
/// by the assertion after it, never concurrently.
private final class RecordingHelper: NSObject, VaderCleanerHelperProtocol, @unchecked Sendable {
    private let replyError: Error?
    private(set) var deletionRequests: [[String]] = []

    init(replyError: Error?) { self.replyError = replyError }

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {
        deletionRequests.append(paths)
        reply(replyError)
    }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushDNSCache(reply: @escaping (Error?) -> Void) { reply(nil) }
    func reindexSpotlight(reply: @escaping (Error?) -> Void) { reply(nil) }
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) { reply(nil) }
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) { reply([], [], nil) }
}

/// Drops every reply block — models a dead NSXPCConnection where the
/// connection-level error handler fires instead of the per-call reply.
/// `@unchecked Sendable`: stateless.
private final class DroppingHelper: NSObject, VaderCleanerHelperProtocol, @unchecked Sendable {
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
