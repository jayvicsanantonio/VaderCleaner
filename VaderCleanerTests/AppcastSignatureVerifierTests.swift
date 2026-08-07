// AppcastSignatureVerifierTests.swift
// Tests Ed25519 verification of a Sparkle appcast enclosure against the installed bundle's SUPublicEDKey, using generated keypairs so no fixture key or network is involved.

import CryptoKit
import XCTest
@testable import VaderCleaner

final class AppcastSignatureVerifierTests: XCTestCase {

    private let payload = Data("a downloaded application archive".utf8)

    // MARK: - Accepting

    /// A signature made by the key the installed bundle advertises is the
    /// only thing that proves the download came from the same developer.
    func test_verify_acceptsSignatureFromTheAdvertisedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: payload)

        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: payload,
                edSignature: signature.base64EncodedString(),
                publicEDKey: key.publicKey.rawRepresentation.base64EncodedString()
            ),
            .valid
        )
    }

    // MARK: - Rejecting

    /// A signature from a different key is the hijacked-feed case: an
    /// attacker who controls the appcast still cannot sign for the
    /// developer's key.
    func test_verify_rejectsSignatureFromAnotherKey() throws {
        let attacker = Curve25519.Signing.PrivateKey()
        let developer = Curve25519.Signing.PrivateKey()
        let signature = try attacker.signature(for: payload)

        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: payload,
                edSignature: signature.base64EncodedString(),
                publicEDKey: developer.publicKey.rawRepresentation.base64EncodedString()
            ),
            .invalid
        )
    }

    /// Tampering with the payload after signing must fail — this is the
    /// check that catches a swapped download.
    func test_verify_rejectsModifiedPayload() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: payload)

        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: Data("a different archive".utf8),
                edSignature: signature.base64EncodedString(),
                publicEDKey: key.publicKey.rawRepresentation.base64EncodedString()
            ),
            .invalid
        )
    }

    // MARK: - Unverifiable

    /// A feed with no `edSignature` cannot be verified. That is distinct
    /// from failing verification: the honest answer is "no evidence",
    /// which callers must treat as "do not auto-install" rather than as
    /// an attack.
    func test_verify_reportsUnverifiableWhenSignatureAbsent() {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: payload,
                edSignature: nil,
                publicEDKey: key.publicKey.rawRepresentation.base64EncodedString()
            ),
            .unverifiable
        )
    }

    /// A bundle with no `SUPublicEDKey` — Sparkle 1 era, which is what
    /// Telegram's feed still is — gives us nothing to check against.
    func test_verify_reportsUnverifiableWhenBundleAdvertisesNoKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: payload)
        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: payload,
                edSignature: signature.base64EncodedString(),
                publicEDKey: nil
            ),
            .unverifiable
        )
    }

    /// A malformed *key* is unverifiable: the key comes from the installed
    /// bundle, so a bad one means we have nothing to check against rather
    /// than evidence against the download.
    func test_verify_reportsUnverifiableForMalformedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: payload).base64EncodedString()

        XCTAssertEqual(
            AppcastSignatureVerifier.verify(data: payload, edSignature: signature, publicEDKey: "not base64!"),
            .unverifiable
        )
    }

    /// A malformed *signature* is invalid, not unverifiable. The signature
    /// is the one field a hostile feed controls, so letting undecodable
    /// base64 report "no evidence" would hand it a downgrade: corrupt your
    /// own signature and the hard refusal becomes the softer path.
    func test_verify_rejectsMalformedSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let goodKey = key.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertEqual(
            AppcastSignatureVerifier.verify(data: payload, edSignature: "not base64!", publicEDKey: goodKey),
            .invalid
        )
    }

    /// A wrong-length signature decodes cleanly but cannot be a valid
    /// Ed25519 signature, and must not be mistaken for an absent one.
    func test_verify_rejectsWrongLengthSignature() throws {
        let key = Curve25519.Signing.PrivateKey()

        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: payload,
                edSignature: Data("short".utf8).base64EncodedString(),
                publicEDKey: key.publicKey.rawRepresentation.base64EncodedString()
            ),
            .invalid
        )
    }

    /// Well-formed base64 that isn't a valid Ed25519 key is unverifiable
    /// rather than a trap — `PublicKey(rawRepresentation:)` throws on a
    /// wrong-length key and that must not propagate.
    func test_verify_reportsUnverifiableForWrongLengthKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: payload).base64EncodedString()
        XCTAssertEqual(
            AppcastSignatureVerifier.verify(
                data: payload,
                edSignature: signature,
                publicEDKey: Data("short".utf8).base64EncodedString()
            ),
            .unverifiable
        )
    }

    /// Empty strings are treated as absent, matching how the rest of the
    /// pipeline reads empty Info.plist values.
    func test_verify_treatsEmptyStringsAsAbsent() {
        XCTAssertEqual(
            AppcastSignatureVerifier.verify(data: payload, edSignature: "", publicEDKey: ""),
            .unverifiable
        )
    }
}
