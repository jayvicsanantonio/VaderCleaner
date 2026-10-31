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
                          bundle: .module,
                          comment: "Auto-install refusal for an archive format we don't expand.")
        case .noApplicationInArchive:
            return String(localized: "The download didn't contain an application.",
                          bundle: .module,
                          comment: "Auto-install failure when an archive has no .app inside.")
        case .toolFailed(let tool):
            return String(localized: "\(tool) couldn't expand the download.",
                          bundle: .module,
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
    static func live(onDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }) -> UpdateInstaller {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaderCleanerUpdates/\(UUID().uuidString)", isDirectory: true)
        let tools = UpdateInstallTools(
            workingDirectory: workingDirectory,
            onDownloadProgress: onDownloadProgress
        )
        return UpdateInstaller(
            download: { url in try await tools.download(url) },
            extract: { archive in try await tools.extractApplication(from: archive) },
            readSignature: { CodeSignatureReader().signature(of: $0) },
            readBundleIdentifier: { Bundle(url: $0)?.bundleIdentifier },
            readBundleVersion: { UpdateInstallTools.bundleVersion(of: $0) },
            isSignedByTeam: { CodeSignatureReader().isSigned($0, byTeam: $1) },
            isRunning: { !UpdateInstallTools.runningCopies(of: $0).isEmpty },
            quit: { await UpdateInstallTools.quit($0) },
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
    /// Injected so tests can serve canned bytes without a network.
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumBytes: Int64
    private let onDownloadProgress: @Sendable (Double) -> Void

    init(
        workingDirectory: URL,
        sessionConfiguration: URLSessionConfiguration = UpdateInstallTools.defaultSessionConfiguration(),
        maximumBytes: Int64 = UpdateInstaller.maximumDownloadBytes,
        onDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) {
        self.workingDirectory = workingDirectory
        self.sessionConfiguration = sessionConfiguration
        self.maximumBytes = maximumBytes
        self.onDownloadProgress = onDownloadProgress
    }

    /// Gives up on a server that goes quiet for a minute, while a large download
    /// that keeps moving may take as long as it needs.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        return configuration
    }

    // MARK: - Download

    func download(_ url: URL) async throws -> URL {
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let destination = workingDirectory
            .appendingPathComponent(Self.downloadFilename(for: url), isDirectory: false)
        let delegate = CappedDownloadDelegate(
            destination: destination,
            maximumBytes: maximumBytes,
            onProgress: onDownloadProgress
        )
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
        return destination
    }

    /// The local filename an enclosure is written to.
    ///
    /// The feed does not get to choose where its download lands.
    /// `URL.lastPathComponent` percent-decodes, so an enclosure URL ending
    /// in `..%2F..%2Fevil.plist` hands back a *relative path* rather than a
    /// name — and appending that to the working directory walks straight
    /// out of it. That write happens before the signature check and before
    /// `UpdateInstallGate` has said anything, so none of the verification
    /// downstream is standing between a hostile appcast and the filesystem.
    ///
    /// Only the extension survives, because it is the sole part of the name
    /// this code ever reads (`extractApplication(from:)` switches on it).
    /// It is dropped unless it is alphanumeric, so the sanitising can't be
    /// smuggled past with an extension that is itself a path.
    static func downloadFilename(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "update"
        }
        return "update.\(ext)"
    }

    // MARK: - Version

    /// The version `bundle` declares: `CFBundleShortVersionString`, falling
    /// back to `CFBundleVersion`.
    ///
    /// The same keys, in the same order, read from the same file as
    /// `DefaultAppDiscovery` reads the installed app's version — the two
    /// are compared to decide whether this is a rollback, so they have to
    /// mean the same thing.
    static func bundleVersion(of bundle: URL) -> String? {
        let infoPlistURL = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any] else {
            return nil
        }
        return (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
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
        let copied = Result { () throws -> URL in
            let application = try firstApplication(in: mountPoint)
            let copied = destination.appendingPathComponent(application.lastPathComponent)
            try? fileManager.removeItem(at: copied)
            try fileManager.copyItem(at: application, to: copied)
            return copied
        }
        // Awaited rather than fired off: the working directory is removed as
        // soon as the attempt ends, and that walk mustn't meet a live mount.
        try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        return try copied.get()
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

    /// Running instances of this exact copy. Matching on the bundle ID alone
    /// would quit a second copy the update isn't touching.
    static func runningCopies(of update: UpdateInfo) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: update.bundleID).filter {
            $0.bundleURL?.standardizedFileURL == update.bundleURL.standardizedFileURL
        }
    }

    /// Asks every instance to quit and waits briefly for them to go.
    /// Returns whether the app actually exited — a swap must not proceed
    /// over a live process.
    static func quit(_ update: UpdateInfo) async -> Bool {
        let running = await MainActor.run { runningCopies(of: update) }
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
            try? await Task.sleep(for: .milliseconds(250))
            let stillRunning = await MainActor.run { runningCopies(of: update) }
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

/// Runs one enclosure download, stopping it the moment it passes the size
/// ceiling. Checking only once the download finished would leave a hostile feed
/// free to fill the disk first, which is what the ceiling exists to prevent.
///
/// `@unchecked Sendable`: `URLSession` delivers these callbacks one at a time on
/// its serial delegate queue, and `start` sets the continuation before the task
/// resumes, so no two accesses to the mutable state overlap.
private final class CappedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReportedPercent = -1

    init(destination: URL, maximumBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.onProgress = onProgress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= maximumBytes, totalBytesExpectedToWrite <= maximumBytes else {
            failure = UpdateDownloadTooLarge(reportedBytes: max(totalBytesWritten, totalBytesExpectedToWrite))
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        onProgress(Double(percent) / 100)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes its temporary file when this returns, so it has to
        // be moved somewhere we own here or not at all.
        guard failure == nil else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            failure = URLError(.badServerResponse)
            return
        }
        // Enforced on what actually landed as well: `didWriteData` isn't
        // promised for every byte, and `Content-Length` is advertised by the
        // same host serving the bytes.
        let landedBytes = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        guard let landedBytes, landedBytes <= maximumBytes else {
            failure = UpdateDownloadTooLarge(reportedBytes: landedBytes)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
