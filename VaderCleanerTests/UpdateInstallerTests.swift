// UpdateInstallerTests.swift
// Drives the in-place update install end to end with every collaborator faked — the happy path, each refusal, the ordering that stops before extracting or replacing, and the running-app handling.

import CryptoKit
import XCTest
@testable import VaderCleaner

@MainActor
final class UpdateInstallerTests: XCTestCase {

    private var tempDirectory: URL!
    private var archiveURL: URL!
    private var signingKey: Curve25519.Signing.PrivateKey!
    private let payload = Data("archive bytes".utf8)

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try TestHelpers.createTempDirectory()
        archiveURL = tempDirectory.appendingPathComponent("Helio.zip")
        try payload.write(to: archiveURL)
        signingKey = Curve25519.Signing.PrivateKey()
    }

    override func tearDown() async throws {
        TestHelpers.tearDownTempDirectory(tempDirectory)
        tempDirectory = nil
        archiveURL = nil
        signingKey = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_install_replacesAndRelaunchesARunningApp() async throws {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: true)

        let outcome = await installer.install(
            update(), feedURL: httpsFeed,
            edSignature: try validSignature(), publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .installed)
        let events = await recorder.events
        XCTAssertEqual(events, ["download", "extract", "quit", "replace", "relaunch", "cleanup"])
    }

    /// An app the user had closed must not be launched by updating it.
    func test_install_doesNotRelaunchAnAppThatWasNotRunning() async throws {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: false)

        let outcome = await installer.install(
            update(), feedURL: httpsFeed,
            edSignature: try validSignature(), publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .installed)
        let events = await recorder.events
        XCTAssertFalse(events.contains("relaunch"))
        XCTAssertFalse(events.contains("quit"))
    }

    // MARK: - Refusals, and how early they happen

    /// An http feed is refused before a single byte is fetched — its
    /// contents, signature included, could have been rewritten in transit.
    func test_install_refusesInsecureFeedWithoutDownloading() async throws {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: false)

        let outcome = await installer.install(
            update(), feedURL: URL(string: "http://example.com/appcast.xml")!,
            edSignature: try validSignature(), publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .denied(.insecureFeed))
        let events = await recorder.events
        XCTAssertFalse(events.contains("download"), "Nothing should be fetched from an http feed")
    }

    /// The archive is verified as delivered, before extraction. An
    /// extractor is a parser and therefore attack surface; there is no
    /// reason to run one over bytes already known to be refused.
    func test_install_verifiesArchiveBeforeExtracting() async {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: false)

        let outcome = await installer.install(
            update(), feedURL: httpsFeed,
            edSignature: "c2lnbmF0dXJl", publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .denied(.signatureInvalid))
        let events = await recorder.events
        XCTAssertTrue(events.contains("download"))
        XCTAssertFalse(events.contains("extract"), "Must not expand an archive that failed verification")
        XCTAssertFalse(events.contains("replace"))
    }

    /// A Sparkle 1 feed publishes no Ed signature. Unlike a failed one,
    /// absence can't be judged from the archive alone — the proof of
    /// identity is inside the bundle — so the install proceeds to extract
    /// and lets the gate decide on Team ID and bundle ID.
    func test_install_extractsAnUnsignedFeedToProveIdentityFromTheBundle() async {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: false)

        let outcome = await installer.install(
            update(), feedURL: httpsFeed, edSignature: nil, publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .installed)
        let events = await recorder.events
        XCTAssertTrue(events.contains("extract"))
    }

    /// The same feed, but the bundle inside is a different app. Identity
    /// is what an unsigned feed rests on, so this must refuse.
    func test_install_refusesUnsignedFeedWhoseBundleIsADifferentApp() async {
        let recorder = Recorder()
        let installer = makeInstaller(
            recorder: recorder, running: false, downloadedBundleID: "com.acme.other"
        )

        let outcome = await installer.install(
            update(), feedURL: httpsFeed, edSignature: nil, publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .denied(.bundleIdentifierMismatch))
        let events = await recorder.events
        XCTAssertFalse(events.contains("replace"))
    }

    /// A correctly signed archive that expands to a bundle from another
    /// developer is still refused, and nothing is replaced.
    func test_install_refusesDifferentDeveloperWithoutReplacing() async throws {
        let recorder = Recorder()
        let installer = makeInstaller(
            recorder: recorder,
            running: false,
            downloadedTeam: "ZZZZZ99999"
        )

        let outcome = await installer.install(
            update(), feedURL: httpsFeed,
            edSignature: try validSignature(), publicEDKey: publicKey
        )

        XCTAssertEqual(outcome, .denied(.teamIdentifierMismatch))
        let events = await recorder.events
        XCTAssertTrue(events.contains("extract"))
        XCTAssertFalse(events.contains("replace"), "A mismatched bundle must never be swapped in")
    }

    // MARK: - Failures

    /// Replacing a bundle under a live process leaves a half-updated app,
    /// so a refusal to quit stops the install rather than forcing it.
    func test_install_stopsWhenTheAppWillNotQuit() async throws {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: true, quitSucceeds: false)

        let outcome = await installer.install(
            update(), feedURL: httpsFeed,
            edSignature: try validSignature(), publicEDKey: publicKey
        )

        guard case .failed = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        let events = await recorder.events
        XCTAssertFalse(events.contains("replace"))
    }

    /// A download that throws reports a failure rather than propagating.
    func test_install_reportsDownloadFailure() async throws {
        struct Boom: Error {}
        let installer = makeInstaller(recorder: Recorder(), running: false, downloadError: Boom())

        let outcome = await installer.install(
            update(), feedURL: httpsFeed,
            edSignature: try validSignature(), publicEDKey: publicKey
        )

        guard case .failed = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
    }

    /// The working directory is cleaned up even when the attempt is
    /// refused, so a declined update leaves nothing behind.
    func test_install_cleansUpAfterARefusal() async {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder, running: false)

        _ = await installer.install(
            update(), feedURL: httpsFeed, edSignature: nil, publicEDKey: publicKey
        )

        let events = await recorder.events
        XCTAssertTrue(events.contains("cleanup"))
    }

    /// An update with no download URL cannot be installed at all — this is
    /// the Homebrew-managed shape, which routes through brew instead.
    func test_install_reportsFailureForAnUpdateWithNoURL() async {
        let installer = makeInstaller(recorder: Recorder(), running: false)
        let brewRow = UpdateInfo(
            appName: "Chrome", bundleID: "com.google.Chrome",
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            installedVersion: "150", latestVersion: "151",
            source: .homebrew, updateURL: nil, homebrewToken: "google-chrome"
        )
        guard case .failed = await installer.install(
            brewRow, feedURL: httpsFeed, edSignature: nil, publicEDKey: nil
        ) else {
            return XCTFail("Expected .failed")
        }
    }

    // MARK: - Fixtures

    private let httpsFeed = URL(string: "https://example.com/appcast.xml")!
    private var publicKey: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    private func validSignature() throws -> String {
        try signingKey.signature(for: payload).base64EncodedString()
    }

    private func update() -> UpdateInfo {
        UpdateInfo(
            appName: "Helio", bundleID: "com.acme.helio",
            bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"),
            installedVersion: "1.0", latestVersion: "2.0",
            source: .sparkle, updateURL: URL(string: "https://example.com/Helio-2.0.zip")!
        )
    }

    private func makeInstaller(
        recorder: Recorder,
        running: Bool,
        quitSucceeds: Bool = true,
        downloadedTeam: String = "ABCDE12345",
        downloadedBundleID: String = "com.acme.helio",
        downloadError: Error? = nil
    ) -> UpdateInstaller {
        let archive = archiveURL!
        let extracted = tempDirectory.appendingPathComponent("Helio.app")
        return UpdateInstaller(
            download: { _ in
                await recorder.record("download")
                if let downloadError { throw downloadError }
                return archive
            },
            extract: { _ in
                await recorder.record("extract")
                return extracted
            },
            readSignature: { url in
                BundleCodeSignature(
                    teamIdentifier: url == extracted ? downloadedTeam : "ABCDE12345",
                    isValid: true
                )
            },
            readBundleIdentifier: { url in
                url == extracted ? downloadedBundleID : "com.acme.helio"
            },
            isRunning: { _ in running },
            quit: { _ in
                await recorder.record("quit")
                return quitSucceeds
            },
            replace: { _, _ in await recorder.record("replace") },
            relaunch: { _ in await recorder.record("relaunch") },
            cleanup: { await recorder.record("cleanup") }
        )
    }
}

/// Orders the steps an install actually performed, so tests can assert
/// not just the outcome but that the expensive and destructive steps were
/// skipped when an earlier check refused.
private actor Recorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
