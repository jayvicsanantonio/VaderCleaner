// SystemPathProviding.swift
// Resolves the macOS filesystem locations that contribute to a System Junk scan, returning a list of ScanRoot pairs that FileScanner can consume.

import Foundation

/// Test seam between `SystemJunkScanner` and the real macOS path layout.
/// Implementations return the concrete `[ScanRoot]` to feed into a scan.
/// Tests inject a stub returning paths under a temp directory, which is why
/// the production `DefaultSystemPathProvider` lives behind the same protocol
/// instead of being a free function on the scanner.
protocol SystemPathProviding {
    func roots() -> [ScanRoot]
}

/// Production implementation that resolves real macOS junk paths plus
/// non-active language `.lproj` directories. Constructed once per scan —
/// volume enumeration and `.lproj` walking happen at call time so a newly
/// mounted volume or freshly installed app shows up on the next run.
struct DefaultSystemPathProvider: SystemPathProviding {

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let languageFileLocator: LanguageFileLocator

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        languageFileLocator: LanguageFileLocator? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.languageFileLocator = languageFileLocator
            ?? LanguageFileLocator(
                scanRoots: Self.defaultLanguageScanRoots(homeDirectory: homeDirectory),
                activeLanguageCodes: Self.activePreferredLanguageCodes()
            )
    }

    /// Roots searched for `.lproj` bundles. Deviation from the plan, which
    /// names `/Library` and `/System/Library`: `/System/Library` lives on the
    /// read-only Signed System Volume and its `.lproj` files cannot be
    /// deleted, so reporting them as "junk" misleads the user. We restrict
    /// to user-installed locations: `/Applications` (system-wide installs)
    /// and `~/Applications` (per-user installs — Codex review on PR #28
    /// flagged that omitting this missed the entire language-files
    /// category for non-admin app installs), plus `/Library/Application Support`
    /// and `/Library/Frameworks` for third-party resources.
    static func defaultLanguageScanRoots(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
            URL(fileURLWithPath: "/Library/Frameworks", isDirectory: true)
        ]
    }

    func roots() -> [ScanRoot] {
        var roots: [ScanRoot] = []

        // User-domain paths — readable in-process, no helper needed.
        let userLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        roots.append(ScanRoot(url: userLibrary.appendingPathComponent("Caches", isDirectory: true), category: .userCache))
        roots.append(ScanRoot(url: userLibrary.appendingPathComponent("Logs", isDirectory: true), category: .userLogs))
        roots.append(ScanRoot(url: userLibrary.appendingPathComponent("Mail Downloads", isDirectory: true), category: .mailAttachments))
        roots.append(ScanRoot(
            url: userLibrary
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("MobileSync", isDirectory: true)
                .appendingPathComponent("Backup", isDirectory: true),
            category: .iosBackups
        ))

        // System-domain paths — readable when Full Disk Access is granted.
        // Privileged enumeration via the helper is deferred to Prompt 14
        // where it pairs with helper-driven deletion; FileScanner's
        // permission-error tolerance keeps the in-process walk safe.
        roots.append(ScanRoot(url: URL(fileURLWithPath: "/Library/Caches", isDirectory: true), category: .systemCache))
        roots.append(ScanRoot(url: URL(fileURLWithPath: "/Library/Logs", isDirectory: true), category: .systemLogs))

        // Trash — home plus every mounted volume's per-user trash directory.
        roots.append(ScanRoot(url: homeDirectory.appendingPathComponent(".Trash", isDirectory: true), category: .trash))
        roots.append(contentsOf: volumeTrashRoots())

        // Language files — non-active `.lproj` directories under
        // `defaultLanguageScanRoots`, each emitted as its own ScanRoot so
        // `FileScanner` tags every file inside as `.languageFiles`.
        roots.append(contentsOf: languageFileLocator.locate())

        return roots
    }

    /// Per-user Trash directories for every mounted, *local* volume except
    /// the boot volume. macOS stores them at `/Volumes/<name>/.Trashes/<uid>`.
    ///
    /// Three filters apply, each pinned by review feedback on PR #28:
    /// - **Boot volume skip** — its trash is `~/.Trash`, already added above.
    ///   Reported by CodeRabbit; the previous comment promised this skip but
    ///   never implemented it, so a `/Volumes/Macintosh HD/.Trashes/<uid>`
    ///   firmlink could double-count via path aliasing.
    /// - **Local-only** — network shares (SMB/AFP) can be wildly slow to
    ///   enumerate and shouldn't contribute to a *system* junk scan.
    ///   Reported by Gemini.
    /// - **Trash exists** — we drop volumes with no per-user trash yet so
    ///   we don't emit empty roots that just create log noise downstream.
    private func volumeTrashRoots() -> [ScanRoot] {
        let uid = String(getuid())
        let bootVolumeURL = (try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeURLKey])
            .volume)?.standardizedFileURL
        let resourceKeys: [URLResourceKey] = [.volumeIsLocalKey, .volumeURLKey]
        let volumes: [URL]
        do {
            volumes = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: "/Volumes", isDirectory: true),
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
        var roots: [ScanRoot] = []
        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: Set(resourceKeys))
            guard values?.volumeIsLocal == true else { continue }
            if let bootVolumeURL,
               let volumeURL = values?.volume?.standardizedFileURL,
               volumeURL == bootVolumeURL {
                continue
            }
            let trash = volume
                .appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(uid, isDirectory: true)
            if fileManager.fileExists(atPath: trash.path) {
                roots.append(ScanRoot(url: trash, category: .trash))
            }
        }
        return roots
    }

    /// Lower-cased language codes treated as active during a system-junk
    /// scan. Used by `LanguageFileLocator` to filter active locales out of
    /// the result. We take only the first component of each preferred
    /// language (`en-US` → `en`) because macOS will fall back from the
    /// regional variant to the base language code at runtime.
    ///
    /// Always includes `"en"` regardless of `Locale.preferredLanguages`.
    /// Most macOS bundles use English as their `CFBundleDevelopmentRegion`
    /// fallback — when a string is missing for the user's preferred locale,
    /// the loader looks up the development region next. Removing
    /// `en.lproj` (or `English.lproj`) from a non-English user's machine
    /// can leave apps with missing UI strings. Reading each bundle's
    /// development region for a per-bundle answer is more accurate but
    /// costly; defaulting to "always preserve English" matches what other
    /// macOS cleaners do and is the safe default. Reported by Codex review
    /// on PR #28.
    static func activePreferredLanguageCodes() -> Set<String> {
        var codes = Set(
            Locale.preferredLanguages.compactMap { tag in
                LanguageFileLocator.languageCode(fromLocaleName: tag)
            }
        )
        codes.insert("en")
        return codes
    }
}
