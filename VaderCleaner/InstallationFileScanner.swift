// InstallationFileScanner.swift
// Shallow-scans the user's Downloads and Desktop for leftover installers (.dmg / .pkg / .iso) and returns them largest-first for the Applications dashboard.

import Foundation
import os.log

/// Production scanner — lists the immediate contents of the user's Downloads
/// and Desktop folders and keeps the disk images and installer packages.
///
/// The scan is intentionally **shallow** (one level per root, no recursion):
/// downloaded installers land directly in Downloads/Desktop, and a recursive
/// walk would risk pulling installers bundled *inside* unrelated folders the
/// user organized on purpose. Keeping it to the top level matches where these
/// files actually accumulate and keeps the scan fast and predictable.
struct DefaultInstallationFileScanner: Sendable {

    private let roots: [URL]
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "InstallationFileScanner")

    /// - Parameter roots: directories to scan, one level deep. Defaults to the
    ///   user's Downloads and Desktop; tests inject temp fixture roots so the
    ///   suite never touches the real folders.
    init(
        roots: [URL] = DefaultInstallationFileScanner.defaultRoots(),
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.fileManager = fileManager
    }

    /// The user's Downloads and Desktop folders — where downloaded installers
    /// accumulate.
    static func defaultRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Downloads", isDirectory: true),
            homeDirectory.appendingPathComponent("Desktop", isDirectory: true),
        ]
    }

    func scan() async -> [InstallationFile] {
        // Hop off the calling actor so the directory listing and per-file stats
        // don't pin the main thread when a Downloads folder holds many items.
        let roots = roots
        let fileManager = fileManager
        let log = log
        return await Task.detached(priority: .userInitiated) {
            var files: [InstallationFile] = []
            var seen = Set<String>()
            for root in roots {
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    // A missing or unreadable root (e.g. no Desktop) must not
                    // sink the rest of the scan.
                    continue
                }
                for entry in entries {
                    guard let kind = InstallationFileKind.forExtension(entry.pathExtension) else {
                        continue
                    }
                    let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    // `.pkg` / `.dmg` / `.iso` are flat files; skip anything
                    // that isn't a regular file (e.g. a folder a user named
                    // "foo.dmg") so we never compute a directory size or offer
                    // to Trash a real folder.
                    guard values?.isRegularFile == true else { continue }
                    // Dedup by path in case a root is listed twice.
                    guard seen.insert(entry.path).inserted else { continue }
                    let size = Int64(values?.fileSize ?? 0)
                    files.append(InstallationFile(
                        url: entry,
                        name: entry.lastPathComponent,
                        sizeBytes: size,
                        kind: kind
                    ))
                }
            }
            // Largest first — the biggest reclaimable installer is what the
            // user most wants to see.
            files.sort { $0.sizeBytes > $1.sizeBytes }
            log.debug("Installation-file scan found \(files.count, privacy: .public) installer(s)")
            return files
        }.value
    }
}
