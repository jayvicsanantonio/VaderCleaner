// HelperCodeSigningRequirementsTests.swift
// Verifies the code-signing requirement each end of the helper XPC connection places on the other: pinned to a signing team whenever there is one, identifier-only only for an ad-hoc build.

import Foundation
import Security
import Testing
@testable import VaderCleanerCore

@Suite
struct HelperCodeSigningRequirementsTests {

    private let appIdentifier = "com.personal.VaderCleaner"
    private let identifierOnly = "identifier \"com.personal.VaderCleaner\""

    private func pinned(to teamIdentifier: String) -> String {
        "identifier \"com.personal.VaderCleaner\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    // MARK: - Requirement construction

    @Test
    func teamIdentifier_isPinnedBehindAnAppleAnchor() {
        let requirement = HelperCodeSigningRequirements.requirement(
            identifier: appIdentifier,
            teamIdentifier: "ABCDE12345"
        )

        #expect(requirement == pinned(to: "ABCDE12345"))
    }

    @Test
    func noTeamIdentifier_leavesTheRequirementIdentifierOnly() {
        let requirement = HelperCodeSigningRequirements.requirement(
            identifier: appIdentifier,
            teamIdentifier: nil
        )

        #expect(requirement == identifierOnly)
    }

    @Test(arguments: ["TEAMID", "TeamID", "teamid", "", "   "])
    func placeholderTeamIdentifier_isNotCompiledIntoTheRequirement(placeholder: String) {
        let requirement = HelperCodeSigningRequirements.requirement(
            identifier: appIdentifier,
            teamIdentifier: placeholder
        )

        #expect(requirement == identifierOnly)
    }

    // MARK: - Choosing the team to pin

    @Test
    func teamSignedProcess_pinsItsPeerToItsOwnTeam() {
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: appIdentifier,
            overrideTeamIdentifier: nil,
            ownSigning: { .team("XGQ94CMBTN") }
        )

        #expect(requirement == pinned(to: "XGQ94CMBTN"))
    }

    @Test
    func adHocProcess_fallsBackToIdentifierOnly() {
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: appIdentifier,
            overrideTeamIdentifier: nil,
            ownSigning: { .adHoc }
        )

        #expect(requirement == identifierOnly)
    }

    /// A process that can't confirm its own signature has nothing honest to
    /// pin, so it fails closed rather than falling back to the identifier.
    @Test
    func unverifiedProcess_acceptsNoPeer() {
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: appIdentifier,
            overrideTeamIdentifier: nil,
            ownSigning: { .unverified }
        )

        #expect(requirement == "never")
    }

    @Test
    func overrideTeam_takesPrecedenceOverTheProcessOwnTeam() {
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: appIdentifier,
            overrideTeamIdentifier: "ABCDE12345",
            ownSigning: { .team("XGQ94CMBTN") }
        )

        #expect(requirement == pinned(to: "ABCDE12345"))
    }

    /// An explicit override fails closed: even a build that somehow shipped
    /// ad-hoc signed still demands the configured team of its peer.
    @Test
    func overrideTeam_pinsThePeerEvenForAnAdHocProcess() {
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: appIdentifier,
            overrideTeamIdentifier: "ABCDE12345",
            ownSigning: { .adHoc }
        )

        #expect(requirement == pinned(to: "ABCDE12345"))
    }

    @Test(arguments: ["TEAMID", "", "   "])
    func placeholderOverride_fallsBackToTheProcessOwnTeam(placeholder: String) {
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: appIdentifier,
            overrideTeamIdentifier: placeholder,
            ownSigning: { .team("XGQ94CMBTN") }
        )

        #expect(requirement == pinned(to: "XGQ94CMBTN"))
    }

    // MARK: - Reading the signing team

    @Test(arguments: ["XGQ94CMBTN", "ABCDE12345", "0123456789"])
    func wellFormedTeamIdentifier_isAccepted(candidate: String) {
        #expect(HelperCodeSigningRequirements.isWellFormedTeamIdentifier(candidate))
    }

    /// A Team ID read from a signature is spliced into a requirement string,
    /// and a crafted signature can carry any text in that field — one that
    /// closes the quote and appends `or always` would accept every peer.
    @Test(arguments: [
        "X\" or always or leaf[subject.OU] = \"",
        "xgq94cmbtn",
        "XGQ94CMBT",
        "XGQ94CMBTNX",
        "XGQ94 CMBT",
        "ＸGQ94CMBTN",
        ""
    ])
    func malformedTeamIdentifier_isRefused(candidate: String) {
        #expect(!HelperCodeSigningRequirements.isWellFormedTeamIdentifier(candidate))
    }

    /// Apple's platform binaries carry a valid signature but no Team ID, so
    /// the reader must report none rather than, say, the signing identifier.
    @Test
    func signingTeamIdentifier_isAbsentForCodeSignedWithoutATeam() throws {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/true") as CFURL, [], &staticCode)
        let code = try #require(status == errSecSuccess ? staticCode : nil)

        #expect(HelperCodeSigningRequirements.signingTeamIdentifier(of: code) == nil)
    }

    // MARK: - Enforcement over a live XPC connection

    /// The probe that exposed the hole, replayed in-process. The test runner
    /// is signed without the pinned team, and it presents exactly the
    /// identifier the listener asks for — the only thing an ad-hoc signer
    /// can forge. A team-pinned requirement must turn it away before any
    /// privileged selector runs.
    @Test(.timeLimit(.minutes(1)))
    func teamPinnedListener_refusesAClientThatOnlyMatchesTheIdentifier() async throws {
        let identifier = try #require(runningProcessSigningIdentifier())
        let spy = HelperProtocolSpy()
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: identifier,
            overrideTeamIdentifier: nil,
            ownSigning: { .team("ABCDE12345") }
        )

        let outcome = await scanDocumentVersions(through: spy, listenerRequirement: requirement)

        #expect(outcome == .rejected)
        #expect(spy.calls.isEmpty)
    }

    /// `never` must be a requirement NSXPCConnection accepts and enforces —
    /// an unparseable one would raise inside the listener instead.
    @Test(.timeLimit(.minutes(1)))
    func unverifiedListener_refusesEveryClient() async throws {
        let identifier = try #require(runningProcessSigningIdentifier())
        let spy = HelperProtocolSpy()
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: identifier,
            overrideTeamIdentifier: nil,
            ownSigning: { .unverified }
        )

        let outcome = await scanDocumentVersions(through: spy, listenerRequirement: requirement)

        #expect(outcome == .rejected)
        #expect(spy.calls.isEmpty)
    }

    /// The requirement a process derives from its own signature is one its
    /// own build satisfies — so the real app and helper, signed alike, still
    /// reach each other whether the build is team-signed or ad-hoc.
    @Test(.timeLimit(.minutes(1)))
    func listenerRequirementDerivedFromItsOwnSignature_acceptsItsOwnBuild() async throws {
        let identifier = try #require(runningProcessSigningIdentifier())
        let spy = HelperProtocolSpy()
        let requirement = HelperCodeSigningRequirements.peerRequirement(
            identifier: identifier,
            overrideTeamIdentifier: nil
        )

        let outcome = await scanDocumentVersions(through: spy, listenerRequirement: requirement)

        #expect(outcome == .replied)
        #expect(spy.calledSelectors == [.scanDocumentVersions])
    }
}

// MARK: - Live XPC harness

/// What a client saw after calling through a live XPC connection.
private enum CallOutcome: Equatable {
    /// The exported object answered.
    case replied
    /// The connection failed before an answer arrived.
    case rejected
    /// The connection never produced a proxy to call through.
    case noProxy
}

/// Calls `scanDocumentVersions` — the selector the original probe used —
/// through a real anonymous XPC connection whose listener applies
/// `listenerRequirement` to every incoming client, as the helper does.
private func scanDocumentVersions(
    through spy: HelperProtocolSpy,
    listenerRequirement: String
) async -> CallOutcome {
    let delegate = RequirementEnforcingListenerDelegate(requirement: listenerRequirement, exportedObject: spy)
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate() }

    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: VaderCleanerHelperProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<CallOutcome, Never>) in
        // NSXPCConnection invokes either the reply block or the error
        // handler, never both; the flag only guards the continuation
        // against a runtime that ever did.
        let resumed = TestBox(false)
        let finish: @Sendable (CallOutcome) -> Void = { outcome in
            let isFirst = resumed.withLock { alreadyResumed in
                defer { alreadyResumed = true }
                return !alreadyResumed
            }
            if isFirst { continuation.resume(returning: outcome) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            finish(.rejected)
        } as? VaderCleanerHelperProtocol
        guard let proxy else {
            finish(.noProxy)
            return
        }
        proxy.scanDocumentVersions { _, _, _ in
            finish(.replied)
        }
    }
    // The listener holds its delegate weakly.
    withExtendedLifetime(delegate) {}
    return outcome
}

/// Stands in for the helper's listener delegate: applies `requirement` to
/// every incoming connection exactly as `VaderCleanerHelper/main.swift`
/// does, then exports the spy in place of the privileged operations.
private final class RequirementEnforcingListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let requirement: String
    private let exportedObject: HelperProtocolSpy

    init(requirement: String, exportedObject: HelperProtocolSpy) {
        self.requirement = requirement
        self.exportedObject = exportedObject
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: VaderCleanerHelperProtocol.self)
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}

/// The signing identifier of the running test process, so a requirement can
/// match it on identifier and differ only in the team it pins.
private func runningProcessSigningIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
          let information = information as? [String: Any] else { return nil }
    return information[kSecCodeInfoIdentifier as String] as? String
}
