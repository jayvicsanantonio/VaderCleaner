// UpdateInstallerLive.swift
// Production wiring for UpdateInstaller — a scratch working directory, URLSession download, zip/dmg extraction via system tools, an atomic bundle swap, and quit/relaunch through AppKit.

import AppKit
import Foundation
import os.log

/// Failures specific to obtaining a replacement bundle, phrased for the
/// user rather than as tool exit codes.
enum UpdateInstallError: LocalizedError {
    case unsupportedArchive(String)
    case noApplicationInArchive
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive(let ext):
            return String(localized: "Updates packaged as .\(ext) can't be installed automatically.",
                          comment: "Auto-install refusal for an archive format we don't expand.")
        case .noApplicationInArchive:
            return String(localized: "The download didn't contain an application.",
                          comment: "Auto-install failure when an archive has no .app inside.")
        case .toolFailed(let tool):
            return String(localized: "\(tool) couldn't expand the download.",
                          comment: "Auto-install failure when a system tool exits non-zero.")
        }
    }
}

extension UpdateInstaller {

    /// Installer wired to the real filesystem, network, and AppKit.
    ///
    /// Each call gets its own scratch directory under the system
    /// temporary location — never Downloads, which is the user's space
    /// and would litter it with archives they never asked to keep.
    @MainActor
    static func live() -> UpdateInstaller {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaderCleanerUpdates/\(UUID().uuidString)", isDirectory: true)
        let tools = UpdateInstallTools(workingDirectory: workingDirectory)
        return UpdateInstaller(
            download: { url in try await tools.download(url) },
            extract: { archive in try await tools.extractApplication(from: archive) },
            readSignature: { CodeSignatureReader().signature(of: $0) },
            isRunning: { bundleID in
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            },
            quit: { bundleID in await UpdateInstallTools.quit(bundleID: bundleID) },
            replace: { replacement, installed in
                try UpdateInstallTools.replace(replacement, into: installed)
            },
            relaunch: { bundle in await UpdateInstallTools.relaunch(bundle) },
            cleanup: { tools.removeWorkingDirectory() }
        )
    }
}

/// The filesystem and process work behind `UpdateInstaller.live()`.
struct UpdateInstallTools: Sendable {

    /// `.default` is documented thread-safe; the scratch directory is
    /// owned by one install attempt.
    nonisolated(unsafe) private let fileManager = FileManager.default
    private let workingDirectory: URL
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "UpdateInstallTools")

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Download

    func download(_ url: URL) async throws -> URL {
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let (temporary, _) = try await URLSession.shared.download(from: url)
        // URLSession deletes its temporary file when the call returns, so
        // it has to be moved somewhere we own before anything else runs.
        let destination = workingDirectory.appendingPathComponent(url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: - Extraction

    /// Expands `archive` and returns the `.app` it contains.
    func extractApplication(from archive: URL) async throws -> URL {
        let destination = workingDirectory.appendingPathComponent("extracted", isDirectory: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        switch archive.pathExtension.lowercased() {
        case "zip":
            // `ditto` rather than `unzip`: it preserves the resource forks
            // and extended attributes an app bundle's signature covers,
            // and a signature that survives extraction is the whole point.
            try await run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
            return try firstApplication(in: destination)
        case "dmg":
            return try await extractFromDiskImage(archive, into: destination)
        default:
            throw UpdateInstallError.unsupportedArchive(archive.pathExtension)
        }
    }

    private func extractFromDiskImage(_ image: URL, into destination: URL) async throws -> URL {
        let mountPoint = workingDirectory.appendingPathComponent("mount", isDirectory: true)
        try await run("/usr/bin/hdiutil", [
            "attach", image.path,
            "-mountpoint", mountPoint.path,
            // `-nobrowse` keeps it out of Finder; `-readonly` and
            // `-noverify` keep an image we are about to inspect from
            // being modified or slow to open.
            "-nobrowse", "-readonly", "-noverify", "-noautoopen"
        ])
        // Detach whatever happens: a leaked mount outlives the app and
        // the user has no obvious way to clear it.
        defer {
            Task { try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        }
        let application = try firstApplication(in: mountPoint)
        let copied = destination.appendingPathComponent(application.lastPathComponent)
        try? fileManager.removeItem(at: copied)
        try fileManager.copyItem(at: application, to: copied)
        return copied
    }

    /// The first `.app` directly inside `directory`. Deliberately shallow:
    /// a nested app is a helper or a decoy, never the payload.
    private func firstApplication(in directory: URL) throws -> URL {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let application = entries.first(where: {
            $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }) else {
            throw UpdateInstallError.noApplicationInArchive
        }
        return application
    }

    /// Runs a system tool with **no pipes attached**.
    ///
    /// That is deliberate. This repo's subprocess hangs come from a
    /// reader waiting on a pipe whose write end a surviving grandchild
    /// still holds (see CLAUDE.md and `DefaultBrewRunnerTests`). With no
    /// pipe there is no reader and no EOF to miss — we only need the exit
    /// status, so nothing is given up by not capturing output.
    private func run(_ launchPath: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.toolFailed((launchPath as NSString).lastPathComponent)
        }
    }

    func removeWorkingDirectory() {
        try? fileManager.removeItem(at: workingDirectory)
    }

    // MARK: - Swap

    /// Atomically swaps `replacement` into `installed`'s place.
    ///
    /// `replaceItemAt` keeps the original until the new item is fully in
    /// place, so a failure mid-swap leaves the working app rather than a
    /// half-written directory where an application used to be.
    static func replace(_ replacement: URL, into installed: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            installed,
            withItemAt: replacement,
            backupItemName: nil,
            options: []
        )
    }

    // MARK: - Quit and relaunch

    /// Asks every instance to quit and waits briefly for them to go.
    /// Returns whether the app actually exited — a swap must not proceed
    /// over a live process.
    static func quit(bundleID: String) async -> Bool {
        let running = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        guard !running.isEmpty else { return true }
        for application in running {
            // `terminate()` is the polite request — it lets the app save
            // and close. Force-killing an editor to install an update
            // would be a poor trade.
            _ = await MainActor.run { application.terminate() }
        }
        // Poll rather than sleep a fixed interval, so a fast quit isn't
        // punished and a slow one still gets a fair chance.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let stillRunning = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            }
            if stillRunning.isEmpty { return true }
        }
        return false
    }

    static func relaunch(_ bundle: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    }
}
