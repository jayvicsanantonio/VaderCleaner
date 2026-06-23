// DownloadsScanner.swift
// Walks ~/Downloads and attributes each file to the app that downloaded it by reading the com.apple.quarantine extended attribute, so the My Clutter card can name the dominant source (e.g. "Google Chrome Downloads").

import Foundation

/// One downloaded file plus the app that fetched it, resolved from the
/// quarantine xattr: `sourceApp` is the display name and `sourceBundleID` the
/// bundle id used to load that app's icon. Both `nil` when the file carries no
/// quarantine provenance.
struct DownloadItem: Equatable, Hashable, Sendable {
    let file: ScannedFile
    let sourceApp: String?
    let sourceBundleID: String?

    init(file: ScannedFile, sourceApp: String?, sourceBundleID: String? = nil) {
        self.file = file
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
    }
}

/// Top-level entry point for the My Clutter "Downloads" card. Walks the user's
/// Downloads folder and reads the `com.apple.quarantine` extended attribute on
/// each file to attribute it to its downloading app. The card uses
/// `dominantSource(of:)` to title itself after the browser that contributed the
/// most bytes (CleanMyMac-style), falling back to a generic label.
struct DownloadsScanner {

    private let fileScanner: FileScanning
    private let downloadsURL: URL?

    /// `downloadsURL` is injectable so tests can point at a temp directory.
    init(
        fileScanner: FileScanning = FileScanner(),
        downloadsURL: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ) {
        self.fileScanner = fileScanner
        self.downloadsURL = downloadsURL
    }

    /// Walks Downloads and returns every non-empty file with its detected
    /// source app, ordered largest first. Honors `excluding`.
    func scan(
        excluding: [URL],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [DownloadItem] {
        guard let downloadsURL else { return [] }

        var items: [DownloadItem] = []
        try await fileScanner.scan(
            roots: [ScanRoot(url: downloadsURL, category: .largeFile)],
            excluding: excluding,
            options: FileScanOptions(packagesAsFiles: true),
            batchSize: FileScanner.defaultBatchSize,
            onProgress: onProgress
        ) { batch in
            for file in batch where file.size > 0 {
                let source = Self.source(of: file.url)
                items.append(DownloadItem(file: file, sourceApp: source?.name, sourceBundleID: source?.bundleID))
            }
            try Task.checkCancellation()
        }
        return items.sorted { $0.file.size > $1.file.size }
    }

    /// The source app contributing the most bytes across `items`, used to title
    /// the card (e.g. "Google Chrome"). Returns `nil` when nothing carries a
    /// known source, so the card falls back to a generic "Downloads" label.
    static func dominantSource(of items: [DownloadItem]) -> String? {
        var bytesBySource: [String: Int64] = [:]
        for item in items {
            guard let source = item.sourceApp else { continue }
            bytesBySource[source, default: 0] += item.file.size
        }
        return bytesBySource.max { $0.value < $1.value }?.key
    }

    // MARK: - Quarantine attribution

    /// Reads `com.apple.quarantine` and resolves the recorded agent to a real
    /// installed app (name + bundle id) via `DownloadSourceResolver`. The xattr
    /// is a `;`-separated string whose third field is the downloading agent —
    /// recorded as a bundle id, display name, or executable depending on the
    /// app. Returns `nil` when there's no quarantine record.
    static func source(of url: URL) -> (name: String, bundleID: String?)? {
        guard let raw = quarantineValue(for: url) else { return nil }
        let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = String(fields[2]).trimmingCharacters(in: .whitespaces)
        guard !agent.isEmpty else { return nil }
        return DownloadSourceResolver.resolve(agent: agent)
    }

    /// Returns the raw `com.apple.quarantine` xattr value for `url`, or `nil`
    /// when the file has none or it can't be read.
    private static func quarantineValue(for url: URL) -> String? {
        let name = "com.apple.quarantine"
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return String(bytes: buffer[0..<read], encoding: .utf8)
    }
}
