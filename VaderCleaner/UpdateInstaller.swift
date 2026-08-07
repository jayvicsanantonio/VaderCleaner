// UpdateInstaller.swift
// Orchestrates installing a Sparkle update in place — download, verify provenance, extract, swap the bundle, relaunch — refusing at the first check that cannot be satisfied.

import Foundation
import os.log

/// What happened when an update was applied.
///
/// `denied` and `failed` are separate because they mean different things
/// to the user: denied is a deliberate refusal with a reason worth
/// showing, failed is something that broke on the way. Both fall back to
/// the same remedy — download it and install by hand.
enum UpdateInstallOutcome: Equatable, Sendable {
    case installed
    case denied(InstallDenial)
    case failed(String)
}

/// Installs a downloaded update over the app it replaces.
///
/// Every collaborator is injected, so the whole flow — including every
/// refusal path — is driven in tests without touching the network, a
/// subprocess, or a real app bundle.
///
/// Ordering is deliberate: nothing is extracted before the archive's
/// signature is checked, and nothing is replaced before the gate allows
/// it. The expensive and destructive steps happen last, after every
/// cheap reason to stop has been considered.
struct UpdateInstaller: Sendable {

    /// Downloads a URL and returns the local file. Implementations write
    /// into a caller-owned temporary directory.
    typealias Download = @Sendable (_ url: URL) async throws -> URL
    /// Expands an archive and returns the `.app` inside it.
    typealias Extract = @Sendable (_ archive: URL) async throws -> URL
    typealias ReadSignature = @Sendable (_ bundle: URL) -> BundleCodeSignature?
    /// The `CFBundleIdentifier` of a bundle on disk, used to prove the
    /// download is the same app rather than merely the same developer.
    typealias ReadBundleIdentifier = @Sendable (_ bundle: URL) -> String?
    /// Whether an app with this bundle ID is currently running.
    typealias IsRunning = @Sendable (_ bundleID: String) -> Bool
    /// Asks the app to quit; returns whether it actually exited.
    typealias Quit = @Sendable (_ bundleID: String) async -> Bool
    /// Swaps `replacement` into `installed`'s place.
    typealias Replace = @Sendable (_ replacement: URL, _ installed: URL) async throws -> Void
    typealias Relaunch = @Sendable (_ bundle: URL) async -> Void
    /// Removes the working directory once the attempt is over.
    typealias Cleanup = @Sendable () async -> Void

    private let download: Download
    private let extract: Extract
    private let readSignature: ReadSignature
    private let readBundleIdentifier: ReadBundleIdentifier
    private let isRunning: IsRunning
    private let quit: Quit
    private let replace: Replace
    private let relaunch: Relaunch
    private let cleanup: Cleanup
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "UpdateInstaller")

    init(
        download: @escaping Download,
        extract: @escaping Extract,
        readSignature: @escaping ReadSignature,
        readBundleIdentifier: @escaping ReadBundleIdentifier = { _ in nil },
        isRunning: @escaping IsRunning,
        quit: @escaping Quit,
        replace: @escaping Replace,
        relaunch: @escaping Relaunch,
        cleanup: @escaping Cleanup = {}
    ) {
        self.download = download
        self.extract = extract
        self.readSignature = readSignature
        self.readBundleIdentifier = readBundleIdentifier
        self.isRunning = isRunning
        self.quit = quit
        self.replace = replace
        self.relaunch = relaunch
        self.cleanup = cleanup
    }

    /// Downloads, verifies, and installs `update` over the app at
    /// `update.bundleURL`.
    ///
    /// - Parameters:
    ///   - feedURL: the appcast the update came from. An http feed is
    ///     refused before anything is fetched.
    ///   - edSignature: the enclosure's `sparkle:edSignature`.
    ///   - publicEDKey: `SUPublicEDKey` from the *installed* bundle.
    func install(
        _ update: UpdateInfo,
        feedURL: URL?,
        edSignature: String?,
        publicEDKey: String?
    ) async -> UpdateInstallOutcome {
        guard let downloadURL = update.updateURL else {
            return .failed("This update has no download.")
        }
        // Refuse an insecure feed before spending a byte of bandwidth:
        // an http appcast can be rewritten in transit, signature included,
        // so nothing it says is worth acting on. Checked before the
        // working directory exists, so there is nothing to clean up.
        if let early = insecureFeedDenial(feedURL) { return early }

        let outcome = await attempt(
            update, downloadURL: downloadURL,
            feedURL: feedURL, edSignature: edSignature, publicEDKey: publicEDKey
        )
        // Awaited rather than deferred into a detached task: a temporary
        // copy of an application is worth removing before we report done,
        // and a fire-and-forget cleanup is untestable besides.
        await cleanup()
        return outcome
    }

    private func attempt(
        _ update: UpdateInfo,
        downloadURL: URL,
        feedURL: URL?,
        edSignature: String?,
        publicEDKey: String?
    ) async -> UpdateInstallOutcome {
        do {
            let archive = try await download(downloadURL)

            // Check the archive as delivered, before expanding it. An
            // extractor is a parser and therefore attack surface, so a
            // signature we can already prove wrong stops here rather than
            // being fed to one.
            //
            // An *absent* signature can't be judged yet — the proof of
            // identity is in the bundle, which means extracting first.
            // The early exit covers what is knowable early; it never
            // claimed to cover everything.
            // `.mappedIfSafe` so verifying a large download costs address
            // space rather than resident memory — an app archive runs to
            // hundreds of megabytes, and the bytes are read once, in order,
            // by the verifier.
            let signature = AppcastSignatureVerifier.verify(
                data: try Data(contentsOf: archive, options: .mappedIfSafe),
                edSignature: edSignature,
                publicEDKey: publicEDKey
            )
            if signature == .invalid {
                return .denied(.signatureInvalid)
            }

            let replacement = try await extract(archive)
            let decision = UpdateInstallGate.decide(
                feedURL: feedURL,
                signature: signature,
                installed: readSignature(update.bundleURL),
                downloaded: readSignature(replacement),
                installedBundleID: update.bundleID,
                downloadedBundleID: readBundleIdentifier(replacement),
                installedVersion: update.installedVersion,
                downloadedVersion: update.latestVersion
            )
            guard case .allow = decision else {
                if case .deny(let reason) = decision { return .denied(reason) }
                return .denied(.downloadNotValidlySigned)
            }

            return await swap(replacement, into: update)
        } catch {
            // Privacy: error text embeds the offending path verbatim.
            log.error("Update install failed: \(String(describing: error), privacy: .private)")
            return .failed(error.localizedDescription)
        }
    }

    /// Quits the app if running, swaps the bundle, and relaunches it only
    /// if it had been running — an update shouldn't launch something the
    /// user had closed.
    private func swap(_ replacement: URL, into update: UpdateInfo) async -> UpdateInstallOutcome {
        let wasRunning = isRunning(update.bundleID)
        if wasRunning, await quit(update.bundleID) == false {
            // Replacing a bundle out from under a running process leaves
            // it in a half-updated state, so a refusal to quit stops the
            // install rather than forcing it.
            return .failed("The app is still running and could not be quit.")
        }
        do {
            try await replace(replacement, update.bundleURL)
        } catch {
            log.error("Bundle swap failed: \(String(describing: error), privacy: .private)")
            return .failed(error.localizedDescription)
        }
        if wasRunning {
            await relaunch(update.bundleURL)
        }
        return .installed
    }

    private func insecureFeedDenial(_ feedURL: URL?) -> UpdateInstallOutcome? {
        guard let feedURL, feedURL.scheme?.lowercased() == "https" else {
            return .denied(.insecureFeed)
        }
        return nil
    }
}
