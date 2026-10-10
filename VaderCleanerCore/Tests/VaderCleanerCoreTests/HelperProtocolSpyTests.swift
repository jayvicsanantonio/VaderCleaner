// HelperProtocolSpyTests.swift
// Pins the shared helper spy's own rules — success by default, which configured reply wins, dropped replies, and the call log — that every helper-facing suite relies on.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct HelperProtocolSpyTests {

    @Test
    func answersEverySelectorWithSuccessByDefault() {
        let spy = HelperProtocolSpy()

        for selector in HelperProtocolSpy.Selector.allCases {
            #expect(answer(of: spy, to: selector) == .success, "\(selector)")
        }
    }

    @Test
    func scanDocumentVersionsAnswersWithAnEmptyListing() throws {
        let spy = HelperProtocolSpy()
        var listing: (paths: [String], sizes: [NSNumber])?

        spy.scanDocumentVersions { paths, sizes, _ in listing = (paths, sizes) }

        let delivered = try #require(listing)
        #expect(delivered.paths.isEmpty)
        #expect(delivered.sizes.isEmpty)
    }

    @Test
    func aSelectorReplyOutranksTheDefaultForThatSelectorAlone() {
        let spy = HelperProtocolSpy(defaultReply: .failure(NSError(domain: "test", code: 3)))
        spy.setReply(.success, for: .flushDNSCache)

        #expect(answer(of: spy, to: .flushDNSCache) == .success)
        #expect(answer(of: spy, to: .flushDNSCache) == .success, "it applies to every call, not just the first")
        #expect(answer(of: spy, to: .reindexSpotlight) == .failure(code: 3))
    }

    /// Calls are counted per selector, so a call to another selector in
    /// between does not shift which call the one-off reply lands on.
    @Test
    func aOneCallReplyOutranksTheSelectorReplyForThatCallAlone() {
        let spy = HelperProtocolSpy()
        spy.setReply(.failure(NSError(domain: "test", code: 1)), for: .deleteFiles)
        spy.setReply(.success, for: .deleteFiles, onCall: 1)

        #expect(answer(of: spy, to: .deleteFiles) == .failure(code: 1))
        #expect(answer(of: spy, to: .flushDNSCache) == .success)
        #expect(answer(of: spy, to: .deleteFiles) == .success)
        #expect(answer(of: spy, to: .deleteFiles) == .failure(code: 1))
    }

    @Test
    func dropNeverInvokesTheReplyBlockButStillRecordsTheCall() {
        let spy = HelperProtocolSpy(defaultReply: .drop)

        for selector in HelperProtocolSpy.Selector.allCases {
            #expect(answer(of: spy, to: selector) == .noReply, "\(selector)")
        }
        #expect(spy.calledSelectors == HelperProtocolSpy.Selector.allCases)
    }

    @Test
    func recordsEveryCallInOrderWithThePathsItNamed() {
        let spy = HelperProtocolSpy()

        spy.deleteFiles(["/a", "/b"]) { _ in }
        spy.removeLaunchAgent(path: "/agent.plist") { _ in }
        spy.flushDNSCache { _ in }
        spy.deleteFiles(["/c"]) { _ in }
        spy.removeLoginItem(path: "/item") { _ in }

        #expect(spy.calls == [
            HelperProtocolSpy.Call(.deleteFiles, paths: ["/a", "/b"]),
            HelperProtocolSpy.Call(.removeLaunchAgent, paths: ["/agent.plist"]),
            HelperProtocolSpy.Call(.flushDNSCache),
            HelperProtocolSpy.Call(.deleteFiles, paths: ["/c"]),
            HelperProtocolSpy.Call(.removeLoginItem, paths: ["/item"]),
        ])
        #expect(spy.calledSelectors == [.deleteFiles, .removeLaunchAgent, .flushDNSCache, .deleteFiles, .removeLoginItem])
        #expect(spy.deleteFilesBatches == [["/a", "/b"], ["/c"]])
        #expect(spy.deleteFilesPaths == ["/a", "/b", "/c"])
        #expect(spy.removeLaunchAgentPaths == ["/agent.plist"])
    }

    // MARK: - Helpers

    /// What a call's reply block delivered.
    private enum Answer: Equatable {
        case success
        case failure(code: Int)
        case noReply
    }

    /// Invokes `selector` on `spy` with placeholder arguments and reports how
    /// the spy answered. The spy replies inside the call, so the answer is
    /// settled by the time the call returns.
    private func answer(of spy: HelperProtocolSpy, to selector: HelperProtocolSpy.Selector) -> Answer {
        var answer = Answer.noReply
        let record: (Error?) -> Void = { error in
            answer = error.map { .failure(code: ($0 as NSError).code) } ?? .success
        }
        switch selector {
        case .deleteFiles: spy.deleteFiles(["/tmp/file"], reply: record)
        case .runMaintenanceScripts: spy.runMaintenanceScripts(reply: record)
        case .removeLoginItem: spy.removeLoginItem(path: "/tmp/item", reply: record)
        case .removeLaunchAgent: spy.removeLaunchAgent(path: "/tmp/agent.plist", reply: record)
        case .flushInactiveMemory: spy.flushInactiveMemory(reply: record)
        case .flushDNSCache: spy.flushDNSCache(reply: record)
        case .reindexSpotlight: spy.reindexSpotlight(reply: record)
        case .thinTimeMachineSnapshots: spy.thinTimeMachineSnapshots(reply: record)
        case .scanDocumentVersions: spy.scanDocumentVersions { _, _, error in record(error) }
        }
        return answer
    }
}
