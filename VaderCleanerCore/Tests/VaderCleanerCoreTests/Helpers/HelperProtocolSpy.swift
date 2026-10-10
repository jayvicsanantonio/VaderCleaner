// HelperProtocolSpy.swift
// The one VaderCleanerHelperProtocol test double — records every XPC call through TestBox and answers each selector with the reply a test configures, success by default.

import Foundation
import VaderCleanerCore

/// Stands in for the privileged helper wherever a test injects a
/// `helperProvider`, so growing the XPC protocol means updating this double
/// rather than a hand-rolled spy in every suite that talks to the helper.
///
/// Each selector records its call, then answers with a `Reply`: `defaultReply`
/// unless `setReply` named one for that selector or for that particular call.
/// The answer arrives synchronously, inside the call. `HelperCall` arms its
/// watchdog only once the call is in flight, so a synchronous reply resolves
/// first and stands it down.
///
/// Checked `Sendable`: final, `NSObject` as its only superclass, and nothing
/// stored but `let`s of `Sendable` types — the call log and the configured
/// replies each sit in a lock-guarded `TestBox`.
final class HelperProtocolSpy: NSObject, VaderCleanerHelperProtocol, Sendable {

    /// The protocol's selectors, by which replies are configured and calls
    /// are recorded.
    enum Selector: CaseIterable, Sendable {
        case deleteFiles
        case runMaintenanceScripts
        case removeLoginItem
        case removeLaunchAgent
        case flushInactiveMemory
        case flushDNSCache
        case reindexSpotlight
        case thinTimeMachineSnapshots
        case scanDocumentVersions
    }

    /// One call the spy received.
    struct Call: Equatable, Sendable {
        let selector: Selector
        /// The paths the call named: the batch for `deleteFiles`, the single
        /// path for `removeLoginItem` and `removeLaunchAgent`, and none for
        /// every other selector.
        let paths: [String]

        init(_ selector: Selector, paths: [String] = []) {
            self.selector = selector
            self.paths = paths
        }
    }

    /// How the spy answers a call.
    enum Reply: Sendable {
        /// Invokes the reply block without an error — and, for
        /// `scanDocumentVersions`, with an empty listing.
        case success
        /// Invokes the reply block with this error.
        case failure(any Error)
        /// Never invokes the reply block: a dead `NSXPCConnection`, where the
        /// connection-level error handler fires instead of the per-call
        /// reply, or a wedged helper, where nothing fires at all.
        case drop
    }

    /// Identifies one call to a selector: the `index`th, counting from zero
    /// and counting only that selector's calls.
    private struct CallSlot: Hashable, Sendable {
        let selector: Selector
        let index: Int
    }

    private let defaultReply: Reply
    private let selectorReplies = TestBox<[Selector: Reply]>([:])
    private let callReplies = TestBox<[CallSlot: Reply]>([:])
    private let log = TestBox<[Call]>([])

    /// - Parameter defaultReply: How every call is answered unless `setReply`
    ///   says otherwise for its selector or for that call.
    init(defaultReply: Reply = .success) {
        self.defaultReply = defaultReply
    }

    // MARK: - Configuring replies

    /// Answers every call to `selector` with `reply`.
    func setReply(_ reply: Reply, for selector: Selector) {
        selectorReplies.withLock { $0[selector] = reply }
    }

    /// Answers only the `callIndex`th call to `selector` with `reply` —
    /// counting from zero, and counting only that selector's calls. It
    /// outranks a reply set for the whole selector.
    func setReply(_ reply: Reply, for selector: Selector, onCall callIndex: Int) {
        callReplies.withLock { $0[CallSlot(selector: selector, index: callIndex)] = reply }
    }

    // MARK: - Recorded calls

    /// Every call received, in order.
    var calls: [Call] { log.value }

    /// The selector of every call received, in order.
    var calledSelectors: [Selector] { calls.map(\.selector) }

    /// The paths of each `deleteFiles` call, in order — one entry per XPC
    /// message, so a chunking test can assert how a batch was split.
    var deleteFilesBatches: [[String]] { paths(sentTo: .deleteFiles) }

    /// Every path sent to `deleteFiles`, across all of its calls.
    var deleteFilesPaths: [String] { deleteFilesBatches.flatMap { $0 } }

    /// Every path sent to `removeLaunchAgent`, in order.
    var removeLaunchAgentPaths: [String] { paths(sentTo: .removeLaunchAgent).flatMap { $0 } }

    private func paths(sentTo selector: Selector) -> [[String]] {
        calls.filter { $0.selector == selector }.map(\.paths)
    }

    // MARK: - VaderCleanerHelperProtocol

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {
        answer(Call(.deleteFiles, paths: paths), reply: reply)
    }

    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {
        answer(Call(.runMaintenanceScripts), reply: reply)
    }

    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) {
        answer(Call(.removeLoginItem, paths: [path]), reply: reply)
    }

    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {
        answer(Call(.removeLaunchAgent, paths: [path]), reply: reply)
    }

    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {
        answer(Call(.flushInactiveMemory), reply: reply)
    }

    func flushDNSCache(reply: @escaping (Error?) -> Void) {
        answer(Call(.flushDNSCache), reply: reply)
    }

    func reindexSpotlight(reply: @escaping (Error?) -> Void) {
        answer(Call(.reindexSpotlight), reply: reply)
    }

    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) {
        answer(Call(.thinTimeMachineSnapshots), reply: reply)
    }

    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) {
        answer(Call(.scanDocumentVersions)) { error in reply([], [], error) }
    }

    // MARK: - Answering

    /// Records `call`, then answers it with the reply set for that call, else
    /// the one set for its selector, else `defaultReply`.
    ///
    /// Recording and counting happen under one lock, so concurrent callers
    /// can neither lose a call nor share a call index.
    private func answer(_ call: Call, reply: (Error?) -> Void) {
        let index = log.withLock { calls in
            calls.append(call)
            return calls.count { $0.selector == call.selector } - 1
        }
        let configured = callReplies.value[CallSlot(selector: call.selector, index: index)]
            ?? selectorReplies.value[call.selector]
            ?? defaultReply

        switch configured {
        case .success: reply(nil)
        case .failure(let error): reply(error)
        case .drop: break
        }
    }
}
