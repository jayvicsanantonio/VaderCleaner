// UpdateInstallGateTests.swift
// Exercises the auto-install decision — every denial path, the ordering that makes an insecure feed decide first, and the Team ID continuity check that holds even when the feed is fully attacker-controlled.

import XCTest
@testable import VaderCleaner

final class UpdateInstallGateTests: XCTestCase {

    private let https = URL(string: "https://example.com/appcast.xml")!
    private let http = URL(string: "http://example.com/appcast.xml")!
    private let signed = BundleCodeSignature(teamIdentifier: "ABCDE12345", isValid: true)

    // MARK: - Allowing

    /// The only combination that permits an install: secure feed, valid
    /// signature, validly signed download, same developer, newer version.
    func test_decide_allowsWhenEveryCheckPasses() {
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: https,
                signature: .valid,
                installed: signed,
                downloaded: signed,
                installedVersion: "1.0",
                downloadedVersion: "2.0"
            ),
            .allow
        )
    }

    // MARK: - Denying

    /// A plain-HTTP feed can be rewritten in transit — including its
    /// signature — so it is rejected before anything downstream is
    /// consulted, even when every other input looks perfect.
    func test_decide_deniesInsecureFeedAheadOfEveryOtherCheck() {
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: http,
                signature: .valid,
                installed: signed,
                downloaded: signed,
                installedVersion: "1.0",
                downloadedVersion: "2.0"
            ),
            .deny(.insecureFeed)
        )
    }

    func test_decide_deniesMissingFeedURL() {
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: nil, signature: .valid, installed: signed, downloaded: signed,
                installedVersion: "1.0", downloadedVersion: "2.0"
            ),
            .deny(.insecureFeed)
        )
    }

    /// A signature that fails is the strongest signal something is wrong.
    func test_decide_deniesInvalidSignature() {
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: https, signature: .invalid, installed: signed, downloaded: signed,
                installedVersion: "1.0", downloadedVersion: "2.0"
            ),
            .deny(.signatureInvalid)
        )
    }

    /// No signature is not permission. This is the common real-world case
    /// — a Sparkle 1 feed like Telegram's — and it must fall back to a
    /// manual download rather than installing on trust.
    func test_decide_deniesUnverifiableSignature() {
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: https, signature: .unverifiable, installed: signed, downloaded: signed,
                installedVersion: "1.0", downloadedVersion: "2.0"
            ),
            .deny(.signatureUnverifiable)
        )
    }

    func test_decide_deniesUnsignedOrInvalidDownload() {
        let unsigned = BundleCodeSignature(teamIdentifier: "ABCDE12345", isValid: false)
        for downloaded in [unsigned, nil] {
            XCTAssertEqual(
                UpdateInstallGate.decide(
                    feedURL: https, signature: .valid, installed: signed, downloaded: downloaded,
                    installedVersion: "1.0", downloadedVersion: "2.0"
                ),
                .deny(.downloadNotValidlySigned)
            )
        }
    }

    /// Without a Team ID on the installed app there is no identity for
    /// the download to continue. Apple's own system apps are exactly this
    /// case, as are ad-hoc builds.
    func test_decide_deniesWhenInstalledAppHasNoTeamIdentifier() {
        let noTeam = BundleCodeSignature(teamIdentifier: nil, isValid: true)
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: https, signature: .valid, installed: noTeam, downloaded: signed,
                installedVersion: "1.0", downloadedVersion: "2.0"
            ),
            .deny(.noInstalledTeamIdentifier)
        )
    }

    /// The check that survives a fully compromised feed: a different
    /// developer's signature is refused even with a valid appcast
    /// signature, because the attacker cannot sign as the developer.
    func test_decide_deniesDifferentDeveloper() {
        let other = BundleCodeSignature(teamIdentifier: "ZZZZZ99999", isValid: true)
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: https, signature: .valid, installed: signed, downloaded: other,
                installedVersion: "1.0", downloadedVersion: "2.0"
            ),
            .deny(.teamIdentifierMismatch)
        )
    }

    /// A download that isn't newer has no business replacing anything —
    /// this is what blocks a downgrade attack via a rolled-back feed.
    func test_decide_deniesSameOrOlderVersion() {
        for version in ["1.0", "0.9"] {
            XCTAssertEqual(
                UpdateInstallGate.decide(
                    feedURL: https, signature: .valid, installed: signed, downloaded: signed,
                    installedVersion: "1.0", downloadedVersion: version
                ),
                .deny(.notNewer)
            )
        }
    }

    /// An uppercase scheme is still https — URL schemes are
    /// case-insensitive and rejecting one would be a false alarm.
    func test_decide_acceptsUppercaseHTTPSScheme() {
        XCTAssertEqual(
            UpdateInstallGate.decide(
                feedURL: URL(string: "HTTPS://example.com/appcast.xml")!,
                signature: .valid, installed: signed, downloaded: signed,
                installedVersion: "1.0", downloadedVersion: "2.0"
            ),
            .allow
        )
    }
}
