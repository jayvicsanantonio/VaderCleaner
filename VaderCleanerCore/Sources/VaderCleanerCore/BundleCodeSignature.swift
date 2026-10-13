// BundleCodeSignature.swift
// Reads an app bundle's code signature — validity, Team ID, and whether an Apple-issued certificate for a team signed it — through the Security framework, so update provenance can be checked without shelling out to codesign.

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

    /// Whether the bundle is validly signed by an Apple-issued certificate
    /// belonging to `teamIdentifier`.
    ///
    /// `signature(of:)` can't answer this. Its Team ID is whatever the
    /// bundle's own signature claims, validated against no requirement,
    /// and a self-signed certificate passes that with any team in its
    /// leaf — Team IDs are public. It is the weakness
    /// `HelperCodeSigningRequirements` guards against for the helper
    /// connection, and it is answered the same way.
    func isSigned(_ bundleURL: URL, byTeam teamIdentifier: String) -> Bool {
        guard let requirement = Self.teamRequirement(for: teamIdentifier) else { return false }
        return satisfies(bundleURL, requirement: requirement)
    }

    /// The requirement that pins a signature to a team, or nil for a value
    /// that can't be a Team ID.
    ///
    /// `anchor apple generic` is the load-bearing clause: a bare
    /// `certificate leaf[subject.OU]` match is satisfied by any self-signed
    /// certificate that simply sets that OU. The team is spliced into
    /// requirement-language source, so anything outside a Team ID's own
    /// alphabet is refused rather than escaped — a quote would otherwise
    /// let the value rewrite the requirement around it.
    static func teamRequirement(for teamIdentifier: String) -> String? {
        guard !teamIdentifier.isEmpty,
              teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Whether the bundle's signature is valid and satisfies `text`, a
    /// requirement in Apple's code-signing requirement language. Text that
    /// doesn't compile, and a bundle with no readable signature, both
    /// count as not satisfied.
    func satisfies(_ bundleURL: URL, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            log.error("Code-signing requirement did not compile")
            return false
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            // Privacy: the path can name a user's app.
            log.debug("No readable signature at \(bundleURL.path, privacy: .private(mask: .hash))")
            return false
        }
        // All architectures for the same reason as `signature(of:)`: a
        // tampered slice for the other one must not pass unnoticed.
        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, checkFlags, requirement) == errSecSuccess
    }
}
