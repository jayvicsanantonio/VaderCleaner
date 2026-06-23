// DownloadsScanner.swift
// Walks ~/Downloads and attributes each file to the app that downloaded it by reading the com.apple.quarantine extended attribute, so the My Clutter card can name the dominant source (e.g. "Google Chrome Downloads").

import Foundation

/// One downloaded file plus the friendly name of the app that fetched it
/// (resolved from the quarantine xattr), or `nil` when the source is unknown.
struct DownloadItem: Equatable, Hashable, Sendable {
    let file: ScannedFile
    let sourceApp: String?
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
                items.append(DownloadItem(file: file, sourceApp: Self.sourceApp(of: file.url)))
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

    /// Reads `com.apple.quarantine` and maps the recorded agent to a friendly
    /// app name. The xattr is a `;`-separated string whose third field is the
    /// downloading agent (e.g. "com.google.Chrome", "com.apple.Safari",
    /// "Firefox"). Returns `nil` when there's no quarantine record.
    static func sourceApp(of url: URL) -> String? {
        guard let raw = quarantineValue(for: url) else { return nil }
        let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = String(fields[2]).trimmingCharacters(in: .whitespaces)
        guard !agent.isEmpty else { return nil }
        return friendlyName(forAgent: agent)
    }

    /// The bundle identifier for a friendly source name, so the dashboard can
    /// resolve the app's real icon. `nil` for sources without a known browser
    /// bundle id (the card then falls back to a file thumbnail).
    static func bundleIdentifier(forSource source: String) -> String? {
        switch source {
        case "Google Chrome": return "com.google.Chrome"
        case "Safari": return "com.apple.Safari"
        case "Firefox": return "org.mozilla.firefox"
        case "Microsoft Edge": return "com.microsoft.edgemac"
        case "Brave": return "com.brave.Browser"
        case "Arc": return "company.thebrowser.Browser"
        case "Opera": return "com.operasoftware.Opera"
        default: return nil
        }
    }

    /// Maps a quarantine agent identifier to a display name. Known bundle ids
    /// get a polished label; anything else is returned as-is so an unrecognised
    /// downloader still attributes correctly.
    static func friendlyName(forAgent agent: String) -> String {
        let lower = agent.lowercased()
        if lower.contains("chrome") { return "Google Chrome" }
        if lower.contains("safari") { return "Safari" }
        if lower.contains("firefox") { return "Firefox" }
        if lower.contains("edge") { return "Microsoft Edge" }
        if lower.contains("brave") { return "Brave" }
        if lower.contains("arc") { return "Arc" }
        if lower.contains("opera") { return "Opera" }
        return agent
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
