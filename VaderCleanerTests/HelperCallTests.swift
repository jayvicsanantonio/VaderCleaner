// HelperCallTests.swift
// Exercises the shared privileged-call bridge — once-only resumption across the reply/error/unavailable paths, and the watchdog that resolves a helper which accepts a call and never answers.

import XCTest
@testable import VaderCleaner

final class HelperCallTests: XCTestCase {

    // MARK: - Normal resolution

    func test_perform_returnsNilWhenTheHelperRepliesWithoutError() async {
        let helper = StubHelper(replyError: nil)

        let error = await HelperCall.perform(helperProvider: { _ in helper }) { helper, reply in
            helper.flushInactiveMemory(reply: reply)
        }

        XCTAssertNil(error)
    }

    func test_perform_surfacesTheReplyError() async {
        let expected = NSError(domain: "test", code: 7)
        let helper = StubHelper(replyError: expected)

        let error = await HelperCall.perform(helperProvider: { _ in helper }) { helper, reply in
            helper.flushInactiveMemory(reply: reply)
        }

        XCTAssertEqual((error as NSError?)?.code, 7)
    }

    func test_perform_reportsUnavailableWhenTheProxyCannotBeBuilt() async {
        let error = await HelperCall.perform(helperProvider: { _ in nil }) { helper, reply in
            helper.flushInactiveMemory(reply: reply)
        }

        XCTAssertEqual(error as? HelperConnectionError, .unavailable)
    }

    /// `NSXPCConnection` may fire the connection-level error handler *instead
    /// of* the per-call reply block. The await must still resolve.
    func test_perform_resolvesViaTheConnectionErrorHandlerWhenTheReplyIsDropped() async {
        let helper = SilentHelper()
        let connectionError = NSError(domain: NSCocoaErrorDomain, code: 4099)

        let error = await HelperCall.perform(
            helperProvider: { errorHandler in
                // Fire the connection handler the way a dropped connection does.
                errorHandler(connectionError)
                return helper
            },
            { helper, reply in helper.flushInactiveMemory(reply: reply) }
        )

        XCTAssertEqual((error as NSError?)?.code, 4099)
    }

    /// Both paths firing must not trap — `CheckedContinuation` crashes on a
    /// second resume, which is the whole reason the resumer exists.
    func test_perform_toleratesBothTheReplyAndTheErrorHandlerFiring() async {
        let helper = StubHelper(replyError: nil)

        let error = await HelperCall.perform(
            helperProvider: { errorHandler in
                errorHandler(NSError(domain: NSCocoaErrorDomain, code: 4099))
                return helper
            },
            { helper, reply in helper.flushInactiveMemory(reply: reply) }
        )

        // Whichever landed first wins; the assertion is that we got here at all.
        XCTAssertTrue(error == nil || (error as NSError?)?.code == 4099)
    }

    // MARK: - Watchdog

    /// The failure this closes: the helper accepts the call, its work queue
    /// wedges in `waitUntilExit()`, the connection stays valid, and no
    /// callback ever fires. Without the watchdog the await never returns.
    func test_perform_timesOutWhenTheHelperNeverAnswers() async {
        let helper = SilentHelper()

        let error = await HelperCall.perform(
            timeout: .milliseconds(50),
            helperProvider: { _ in helper },
            { helper, reply in helper.flushInactiveMemory(reply: reply) }
        )

        XCTAssertEqual(error as? HelperConnectionError, .timedOut)
    }

    /// A call that answers normally must not be resolved by the watchdog, and
    /// must not wait for it either.
    func test_perform_returnsImmediatelyWhenTheHelperAnswersBeforeTheTimeout() async {
        let helper = StubHelper(replyError: nil)

        let started = DispatchTime.now().uptimeNanoseconds
        let error = await HelperCall.perform(
            timeout: .seconds(30),
            helperProvider: { _ in helper },
            { helper, reply in helper.flushInactiveMemory(reply: reply) }
        )
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        XCTAssertNil(error)
        XCTAssertLessThan(elapsedMilliseconds, 1_000,
                          "A synchronous reply must not wait on the watchdog")
    }

    /// A timed-out call reads as a connection failure, so the UI offers the
    /// "helper isn't responding" recovery rather than a bare retry.
    func test_timedOut_isTreatedAsAConnectionFailure() {
        XCTAssertTrue(HelperConnectionError.isConnectionFailure(HelperConnectionError.timedOut))
        XCTAssertEqual(
            HelperConnectionError.userFacingMessage(for: HelperConnectionError.timedOut),
            HelperConnectionError.message
        )
    }

    // MARK: - OnceResumer

    func test_onceResumer_dropsEveryResumeAfterTheFirst() async {
        let value: Int = await withCheckedContinuation { continuation in
            let resumer = OnceResumer<Int>(continuation: continuation)
            resumer.resume(returning: 1)
            resumer.resume(returning: 2)
            resumer.resume(returning: 3)
        }

        XCTAssertEqual(value, 1)
    }

    func test_onceResumer_armTimeoutIsStoodDownByAnEarlierResume() async {
        let value: Int = await withCheckedContinuation { continuation in
            let resumer = OnceResumer<Int>(continuation: continuation)
            resumer.resume(returning: 1)
            // Arming after the fact must neither trap nor override.
            resumer.armTimeout(.milliseconds(10)) { 99 }
        }

        XCTAssertEqual(value, 1)
        // Give a leaked watchdog time to fire and trap on a second resume.
        try? await Task.sleep(for: .milliseconds(80))
    }

    func test_onceResumer_armTimeoutResolvesWhenNothingElseDoes() async {
        let value: Int = await withCheckedContinuation { continuation in
            let resumer = OnceResumer<Int>(continuation: continuation)
            resumer.armTimeout(.milliseconds(30)) { 42 }
        }

        XCTAssertEqual(value, 42)
    }
}

// MARK: - Test doubles

/// Replies synchronously with the supplied error (or `nil`).
/// `@unchecked Sendable`: written by the call, read by the assertion after it.
private final class StubHelper: NSObject, VaderCleanerHelperProtocol, @unchecked Sendable {
    private let replyError: Error?

    init(replyError: Error?) {
        self.replyError = replyError
    }

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) { reply(replyError) }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) { reply(replyError) }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(replyError) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) { reply(replyError) }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) { reply(replyError) }
    func flushDNSCache(reply: @escaping (Error?) -> Void) { reply(replyError) }
    func reindexSpotlight(reply: @escaping (Error?) -> Void) { reply(replyError) }
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) { reply(replyError) }
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) {
        reply([], [], replyError)
    }
}

/// Accepts every call and never replies — the wedged-helper case the watchdog
/// exists for. `@unchecked Sendable`: holds no state.
private final class SilentHelper: NSObject, VaderCleanerHelperProtocol, @unchecked Sendable {
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
