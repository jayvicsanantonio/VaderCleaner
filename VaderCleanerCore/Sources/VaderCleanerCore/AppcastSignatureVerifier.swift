// AppcastSignatureVerifier.swift
// Verifies a downloaded Sparkle enclosure against the Ed25519 signature in its appcast and the public key the installed bundle advertises.

import CryptoKit
import Foundation

/// Whether a download's provenance could be established.
///
/// `.unverifiable` is deliberately distinct from `.invalid`. A feed that
/// publishes no signature, or a bundle that advertises no key, gives us
/// no evidence either way — that is not an attack, and reporting it as
/// one would be wrong. But it is also not permission to install: callers
/// must treat it as "download only", never as "proceed".
enum AppcastSignatureResult: Hashable, Sendable {
    case valid
    case invalid
    case unverifiable
}

/// Ed25519 verification of a Sparkle enclosure, the scheme Sparkle 2
/// uses (`sparkle:edSignature` on the enclosure, `SUPublicEDKey` in the
/// app's `Info.plist`).
///
/// The key comes from the **installed** bundle rather than the feed, so
/// an attacker who controls the appcast still cannot authorise a
/// download: they would have to sign with the developer's key, which the
/// app on disk already names.
///
/// Legacy `sparkle:dsaSignature` is not implemented. CryptoKit has no
/// DSA, and the Security-framework path is substantially more work for a
/// deprecated scheme — so DSA-only feeds report `.unverifiable` and fall
/// back to a manual download. Telegram's feed is currently one of those.
enum AppcastSignatureVerifier {

    static func verify(
        data: Data,
        edSignature: String?,
        publicEDKey: String?
    ) -> AppcastSignatureResult {
        guard let edSignature, !edSignature.isEmpty,
              let publicEDKey, !publicEDKey.isEmpty else {
            return .unverifiable
        }
        // The key is resolved first, and separately, because the two fields
        // come from opposite sides of the trust boundary. The key is read
        // from the *installed* bundle, so a malformed one leaves us with
        // nothing to check against — that is genuinely "no evidence".
        // A wrong-length key throws rather than returning nil, and that
        // must not propagate out of a verification call.
        guard let keyBytes = Data(base64Encoded: publicEDKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            return .unverifiable
        }
        // The signature comes from the feed, which is the thing this whole
        // type exists to distrust. A signature that is present but will not
        // decode is a claim that fails to hold up, not an absence of one —
        // reporting it as `.unverifiable` would let a hostile feed downgrade
        // its own hard refusal into the softer path by corrupting the base64
        // it controls.
        guard let signatureBytes = Data(base64Encoded: edSignature) else {
            return .invalid
        }
        return key.isValidSignature(signatureBytes, for: data) ? .valid : .invalid
    }
}
