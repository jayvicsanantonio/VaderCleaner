// UpdateInstallGate.swift
// The single decision point for whether a downloaded update may be installed automatically — every check must pass, and anything unproven denies.

import Foundation

/// Why an update may not be installed automatically. Each maps to copy
/// the user can act on, and every one falls back to the same safe
/// behaviour: download it and let them install by hand.
enum InstallDenial: Hashable, Sendable {
    /// The appcast was fetched over plain HTTP, so its contents — including
    /// the signature itself — could have been rewritten in transit.
    case insecureFeed
    /// A signature was present and did not match. The strongest possible
    /// signal that something is wrong.
    case signatureInvalid
    /// The download is a different app than the one it would replace.
    /// A vendor's Team ID covers everything they ship — Google's signs
    /// Chrome and Drive alike — so identity has to be pinned to the app,
    /// not just the developer.
    case bundleIdentifierMismatch
    /// The downloaded bundle isn't validly signed.
    case downloadNotValidlySigned
    /// The installed app carries no Team ID, so there is no identity to
    /// prove the download continues. True of Apple's own system apps and
    /// of ad-hoc builds.
    case noInstalledTeamIdentifier
    /// The download is signed by a different developer than the app it
    /// would replace.
    case teamIdentifierMismatch
    /// The download isn't actually newer.
    case notNewer
}

enum InstallDecision: Hashable, Sendable {
    case allow
    case deny(InstallDenial)
}

/// Decides whether a downloaded update is safe to install in place.
///
/// The gate exists because installing changes the stakes entirely. While
/// "update" only opens a URL, a hijacked appcast costs the user a bad
/// file in Downloads. The moment we replace the app bundle ourselves,
/// that same feed becomes arbitrary code execution — so this is written
/// to deny by default and allow only when every check passes.
///
/// The load-bearing check is identity continuity, because it does not
/// trust the feed at all. An attacker who fully controls the appcast host
/// still cannot produce a bundle signed by the developer's certificate,
/// so a matching Team ID *and* bundle ID mean the replacement is a
/// genuine build of the same app by whoever signed what is installed.
///
/// A missing appcast signature is therefore **not** a refusal. Sparkle 1
/// feeds sign with DSA, which has no supported verification path left on
/// macOS — `SecTransform` is deprecated as "no longer supported" — so
/// treating absence as refusal would permanently exclude most feeds. And
/// the fallback that refusal drops to is the user downloading the same
/// archive from the same URL and installing it with no checks at all.
/// Installing it here, having proven the developer and the app, is
/// strictly safer than the thing it would otherwise defer to.
///
/// A signature that is *present and fails* stays a hard refusal. Absence
/// means Sparkle 1; failure means something is actively wrong.
enum UpdateInstallGate {

    static func decide(
        feedURL: URL?,
        signature: AppcastSignatureResult,
        installed: BundleCodeSignature?,
        downloaded: BundleCodeSignature?,
        installedBundleID: String,
        downloadedBundleID: String?,
        installedVersion: String,
        downloadedVersion: String
    ) -> InstallDecision {
        // A plain-HTTP feed can be rewritten wholesale in transit, which
        // includes swapping the signature for one matching a hostile
        // payload. Check it first: nothing downstream is trustworthy.
        guard let feedURL, feedURL.scheme?.lowercased() == "https" else {
            return .deny(.insecureFeed)
        }
        if signature == .invalid {
            return .deny(.signatureInvalid)
        }
        guard let downloaded, downloaded.isValid else {
            return .deny(.downloadNotValidlySigned)
        }
        guard let installedTeam = installed?.teamIdentifier else {
            return .deny(.noInstalledTeamIdentifier)
        }
        guard downloaded.teamIdentifier == installedTeam else {
            return .deny(.teamIdentifierMismatch)
        }
        guard downloadedBundleID == installedBundleID else {
            return .deny(.bundleIdentifierMismatch)
        }
        // Blocks a rollback: a hostile host can only serve genuine builds,
        // so pinning the user to an older one is the attack left to it.
        guard VersionComparator.isNewer(version: downloadedVersion, than: installedVersion) else {
            return .deny(.notNewer)
        }
        return .allow
    }
}
