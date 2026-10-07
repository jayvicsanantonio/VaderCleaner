// BundleCodeSignature.swift
// Reads an app bundle's code signature — validity and Team ID — through the Security framework, so update provenance can be checked without shelling out to codesign.

import Foundation
import Security
import os.log

/// What the system knows about a bundle's signature.
///
/// `teamIdentifier` is nil for Apple's own system apps, which are signed
/// by Apple's platform authority and carry no team. It is also nil for
/// ad-hoc and unsigned bundles, and the caller cannot tell those apart —
/// which is why an absent team is treated as "no continuity to prove"
/// rather than as any particular provenance.
struct BundleCodeSignature: Hashable, Sendable {
    let teamIdentifier: String?
    let isValid: Bool
}

/// Reads bundle signatures via `SecStaticCode`.
///
/// Deliberately not a `codesign` subprocess: this repo's child-process
/// tests already wedge `xcodebuild` intermittently (see CLAUDE.md), and
/// the Security framework answers the same question in-process with a
/// typed result instead of scraped output.
struct CodeSignatureReader: Sendable {

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "CodeSignatureReader")

    /// The bundle's signature, or nil when it has none the system can
    /// read at all.
    func signature(of bundleURL: URL) -> BundleCodeSignature? {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            // Privacy: the path can name a user's app.
            log.debug("No readable signature at \(bundleURL.path, privacy: .private(mask: .hash))")
            return nil
        }

        // `kSecCSCheckAllArchitectures` matters on universal binaries:
        // without it a tampered slice for the other architecture would
        // pass unnoticed.
        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let isValid = SecStaticCodeCheckValidity(staticCode, checkFlags, nil) == errSecSuccess

        var information: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &information) == errSecSuccess,
              let details = information as? [String: Any] else {
            return BundleCodeSignature(teamIdentifier: nil, isValid: isValid)
        }
        let team = details[kSecCodeInfoTeamIdentifier as String] as? String
        return BundleCodeSignature(
            teamIdentifier: (team?.isEmpty ?? true) ? nil : team,
            isValid: isValid
        )
    }
}
