// MailReindexer.swift
// Rebuilds the Mail "Envelope Index" SQLite databases (VACUUM; REINDEX) to speed up Mail search. Runs at user level — no privileged helper — and distinguishes "no Full Disk Access" from "no Mail data" so the UI can guide the user.

import Foundation
import os.log

/// Speeds up Mail by compacting and reindexing its envelope-index databases.
/// The index locator and the per-database vacuum are injected so unit tests
/// exercise the flow without touching real Mail data or running `sqlite3`.
struct MailReindexer {

    /// Locates the envelope-index databases. Throwing so it can signal the
    /// difference between "no access" (Full Disk Access missing) and "no mail".
    typealias LocateIndexes = () throws -> [URL]
    typealias VacuumIndex = (URL) throws -> Void

    private let locateIndexes: LocateIndexes
    private let vacuumIndex: VacuumIndex
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "MailReindexer")

    init(
        locateIndexes: @escaping LocateIndexes = MailReindexer.defaultLocateIndexes,
        vacuumIndex: @escaping VacuumIndex = MailReindexer.defaultVacuumIndex
    ) {
        self.locateIndexes = locateIndexes
        self.vacuumIndex = vacuumIndex
    }

    /// Vacuums and reindexes every located envelope index. Throws
    /// `.fullDiskAccessRequired` when `~/Library/Mail` can't be read (the common
    /// case — the app isn't in Full Disk Access), `.noMailData` when Mail simply
    /// has no databases, and rethrows the first vacuum failure (e.g. Mail is
    /// open and holding a lock).
    func run() async throws -> String {
        let indexes = try locateIndexes()
        guard !indexes.isEmpty else {
            throw MailReindexerError.noMailData
        }
        for index in indexes {
            try vacuumIndex(index)
        }
        let format = String(
            localized: "Reindexed %d Mail database(s). Quit and reopen Mail to see the change.",
            comment: "Result line after the Mail envelope indexes are rebuilt; %d is the count."
        )
        return String.localizedStringWithFormat(format, indexes.count)
    }

    // MARK: - Production collaborators

    /// Finds the envelope-index databases under `~/Library/Mail`. Mail stores
    /// them per account-format version at `V<n>/MailData/Envelope Index`, so this
    /// looks only at that shallow, known location rather than walking the whole
    /// (potentially huge) Mail tree. Reading `~/Library/Mail` is gated by Full
    /// Disk Access: a permission failure there means the app hasn't been
    /// granted access, which is reported distinctly from "no mail".
    static func defaultLocateIndexes() throws -> [URL] {
        let mailRoot = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail", isDirectory: true)

        let versionDirs: [URL]
        do {
            versionDirs = try FileManager.default.contentsOfDirectory(
                at: mailRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoPermission {
            throw MailReindexerError.fullDiskAccessRequired
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            // TCC/sandbox denials surface as EPERM or EACCES depending on the
            // API and macOS version — treat both as "needs Full Disk Access".
            throw MailReindexerError.fullDiskAccessRequired
        } catch {
            // No Mail folder (never set up) or some other read error — treat as
            // "nothing to reindex" rather than a permission problem.
            return []
        }

        // Mail's index lives at V<n>/MailData/Envelope Index on current macOS;
        // the bare V<n>/Envelope Index covers older layouts.
        var found: [URL] = []
        // Match version dirs like "V10" — "V" followed by digits — so unrelated
        // folders (e.g. a hypothetical "Vendor") aren't treated as Mail data.
        for dir in versionDirs where isMailVersionDirectory(dir.lastPathComponent) {
            for relative in ["MailData/Envelope Index", "Envelope Index"] {
                let candidate = dir.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found.append(candidate)
                }
            }
        }
        return found
    }

    /// A Mail account-format version directory is "V" followed by one or more
    /// digits (V2…V10…). The digit check avoids matching unrelated folders.
    private static func isMailVersionDirectory(_ name: String) -> Bool {
        let suffix = name.dropFirst()
        return name.hasPrefix("V") && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Runs `/usr/bin/sqlite3 <index> "VACUUM; REINDEX;"`. Throws on a non-zero
    /// exit (a locked database while Mail is open is the common case).
    static func defaultVacuumIndex(_ index: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [index.path, "VACUUM; REINDEX;"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw MailReindexerError.vacuumFailed(
                path: index.path,
                status: process.terminationStatus
            )
        }
    }
}

/// Failures surfaced by `MailReindexer`, with user-facing messages.
enum MailReindexerError: LocalizedError {
    case fullDiskAccessRequired
    case noMailData
    case vacuumFailed(path: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            return String(
                localized: "Speeding up Mail needs Full Disk Access. Grant it in System Settings → Privacy & Security → Full Disk Access, then try again.",
                comment: "Error when MailReindexer can't read ~/Library/Mail because the app lacks Full Disk Access."
            )
        case .noMailData:
            return String(
                localized: "No Mail databases were found to reindex.",
                comment: "Error when MailReindexer finds no envelope-index databases even though it could read the Mail folder."
            )
        case .vacuumFailed:
            return String(
                localized: "Couldn't reindex Mail. Quit Mail and try again.",
                comment: "Error when the Mail envelope-index vacuum fails, usually because Mail is open."
            )
        }
    }
}
