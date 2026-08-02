// UpdateInstallGateTests.swift
// Exercises the auto-install decision — every denial path, the ordering that makes an insecure feed decide first, and the identity continuity that holds even when the feed is fully attacker-controlled.

import XCTest
@testable import VaderCleaner

final class UpdateInstallGateTests: XCTestCase {

    private let https = URL(string: "https://example.com/appcast.xml")!
    private let http = URL(string: "http://example.com/appcast.xml")!
    private let signed = BundleCodeSignature(teamIdentifier: "ABCDE12345", isValid: true)

    /// Every input defaulted to the permitting case, so each test varies
    /// exactly the one thing it is about.
    private func decide(
        feedURL: URL?? = nil,
        signature: AppcastSignatureResult = .valid,
        installed: BundleCodeSignature?? = nil,
        downloaded: BundleCodeSignature?? = nil,
        installedBundleID: String = "com.acme.helio",
        downloadedBundleID: String? = "com.acme.helio",
        installedVersion: String = "1.0",
        downloadedVersion: String = "2.0"
    ) -> InstallDecision {
        UpdateInstallGate.decide(
            feedURL: feedURL ?? https,
            signature: signature,
            installed: installed ?? signed,
            downloaded: downloaded ?? signed,
            installedBundleID: installedBundleID,
            downloadedBundleID: downloadedBundleID,
            installedVersion: installedVersion,
            downloadedVersion: downloadedVersion
        )
    }

    // MARK: - Allowing

    /// The permitting case: secure feed, validly signed download, same
    /// developer, same app, newer version.
    func test_decide_allowsWhenEveryCheckPasses() {
        XCTAssertEqual(decide(), .allow)
    }

    /// A Sparkle 1 feed publishes no Ed signature, and macOS has no
    /// supported way left to check its DSA one. Refusing would exclude
    /// most feeds permanently — and would defer to the user downloading
    /// the same archive from the same URL with no checks at all. Proving
    /// the developer and the app is strictly safer than that.
    func test_decide_allowsUnsignedFeedWhenIdentityIsProven() {
        XCTAssertEqual(decide(signature: .unverifiable), .allow)
    }

    /// An uppercase scheme is still https — URL schemes are
    /// case-insensitive and rejecting one would be a false alarm.
    func test_decide_acceptsUppercaseHTTPSScheme() {
        XCTAssertEqual(decide(feedURL: URL(string: "HTTPS://example.com/appcast.xml")!), .allow)
    }

    // MARK: - Denying

    /// A plain-HTTP feed can be rewritten in transit — including its
    /// signature — so it is rejected before anything downstream is
    /// consulted, even when every other input looks perfect.
    func test_decide_deniesInsecureFeedAheadOfEveryOtherCheck() {
        XCTAssertEqual(decide(feedURL: http), .deny(.insecureFeed))
    }

    func test_decide_deniesMissingFeedURL() {
        XCTAssertEqual(decide(feedURL: .some(nil)), .deny(.insecureFeed))
    }

    /// Absence of a signature is tolerated; failure never is. A signature
    /// that is present and does not match means something is actively
    /// wrong, and no amount of identity evidence redeems it.
    func test_decide_deniesInvalidSignatureEvenWithProvenIdentity() {
        XCTAssertEqual(decide(signature: .invalid), .deny(.signatureInvalid))
    }

    func test_decide_deniesUnsignedOrInvalidDownload() {
        let unsigned = BundleCodeSignature(teamIdentifier: "ABCDE12345", isValid: false)
        for downloaded in [unsigned, nil] {
            XCTAssertEqual(
                decide(downloaded: .some(downloaded)),
                .deny(.downloadNotValidlySigned)
            )
        }
    }

    /// Without a Team ID on the installed app there is no identity for
    /// the download to continue. Apple's own system apps are exactly this
    /// case, as are ad-hoc builds.
    func test_decide_deniesWhenInstalledAppHasNoTeamIdentifier() {
        let noTeam = BundleCodeSignature(teamIdentifier: nil, isValid: true)
        XCTAssertEqual(decide(installed: .some(noTeam)), .deny(.noInstalledTeamIdentifier))
    }

    /// The check that survives a fully compromised feed: a different
    /// developer's signature is refused, because an attacker who owns the
    /// appcast host still cannot sign as the developer.
    func test_decide_deniesDifferentDeveloper() {
        let other = BundleCodeSignature(teamIdentifier: "ZZZZZ99999", isValid: true)
        XCTAssertEqual(decide(downloaded: .some(other)), .deny(.teamIdentifierMismatch))
    }

    /// A Team ID covers everything a vendor ships — Google's signs Chrome
    /// and Drive alike — so without a bundle-ID check an unsigned feed
    /// could swap one of a vendor's apps for another and still pass.
    func test_decide_deniesADifferentAppFromTheSameDeveloper() {
        XCTAssertEqual(
            decide(
                signature: .unverifiable,
                installedBundleID: "com.google.Chrome",
                downloadedBundleID: "com.google.drivefs"
            ),
            .deny(.bundleIdentifierMismatch)
        )
    }

    /// A bundle whose identifier can't be read proves nothing.
    func test_decide_deniesWhenTheDownloadHasNoBundleIdentifier() {
        XCTAssertEqual(decide(downloadedBundleID: nil), .deny(.bundleIdentifierMismatch))
    }

    /// A download that isn't newer has no business replacing anything.
    /// With identity proven, a hostile host can only serve genuine builds,
    /// so pinning the user to an older one is the attack left to it.
    func test_decide_deniesSameOrOlderVersion() {
        for version in ["1.0", "0.9"] {
            XCTAssertEqual(decide(downloadedVersion: version), .deny(.notNewer))
        }
    }
}
