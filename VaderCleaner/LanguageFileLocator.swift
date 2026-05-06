// LanguageFileLocator.swift
// Walks given roots looking for .lproj directories, returning each non-active locale as a .languageFiles ScanRoot.

import Foundation
import os.log

/// Finds `.lproj` directories under a configurable set of scan roots and
/// returns those whose locale is *not* in the active language list. The
/// scanner doesn't recurse arbitrarily deep — `.lproj` only lives one level
/// inside a bundle's `Contents/Resources/`, so a bounded walk is enough and
/// avoids accidentally vacuuming up unrelated content.
///
/// Active-locale matching is by language code (the part before `-` or `_`),
/// not by full locale name. macOS `.lproj` names are a mix of BCP-47
/// (`en-US.lproj`), language-only (`en.lproj`), underscore-separated
/// (`zh_CN.lproj`), and pre-ISO legacy (`English.lproj`, `Spanish.lproj`).
/// Direct equality misses every variant; prefix matching with a small
/// legacy allowlist gets all of them.
struct LanguageFileLocator {

    /// Root directories to walk. Caller chooses these — defaults live in
    /// `DefaultSystemPathProvider` so this type stays unaware of macOS path
    /// conventions and remains trivially testable from any temp directory.
    let scanRoots: [URL]

    /// Lower-cased language codes to treat as active. `.lproj` directories
    /// whose extracted code matches anything here are filtered out of the
    /// returned list.
    let activeLanguageCodes: Set<String>

    private static let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "LanguageFileLocator"
    )

    /// Maps legacy macOS `.lproj` names (used before ISO codes were the
    /// norm) onto their language codes so prefix matching catches them.
    /// Not exhaustive — these are the names still seen in older bundles
    /// shipping today. New entries can be added as we encounter them.
    private static let legacyLanguageNames: [String: String] = [
        "english": "en",
        "spanish": "es",
        "french": "fr",
        "german": "de",
        "italian": "it",
        "japanese": "ja",
        "dutch": "nl"
    ]

    init(scanRoots: [URL], activeLanguageCodes: Set<String>) {
        self.scanRoots = scanRoots
        self.activeLanguageCodes = Set(activeLanguageCodes.map { $0.lowercased() })
    }

    /// Walks each scan root, surfaces every `.lproj` directory whose locale
    /// is non-active, and returns one `ScanRoot(.languageFiles)` per match.
    /// The walk follows package descendants because `.lproj` lives *inside*
    /// `.app` bundles — `FileScanner`'s default `.skipsPackageDescendants`
    /// would hide them otherwise.
    func locate() -> [ScanRoot] {
        var roots: [ScanRoot] = []
        for scanRoot in scanRoots {
            roots.append(contentsOf: lprojRoots(under: scanRoot))
        }
        return roots
    }

    /// Builds the `[ScanRoot]` for a single top-level directory. Pulled out
    /// so each root is independently failure-tolerant: an unreadable
    /// `/Library/Frameworks` doesn't prevent us from walking `/Applications`.
    private func lprojRoots(under url: URL) -> [ScanRoot] {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                Self.log.debug(
                    "Skipping unreadable language path \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                )
                return true
            }
        )
        guard let enumerator else { return [] }

        var roots: [ScanRoot] = []
        for case let entry as URL in enumerator {
            guard entry.pathExtension.caseInsensitiveCompare("lproj") == .orderedSame else {
                continue
            }
            let localeName = entry.deletingPathExtension().lastPathComponent
            guard let code = Self.languageCode(fromLocaleName: localeName) else {
                continue
            }
            if activeLanguageCodes.contains(code) {
                // Active locale — keep its `.lproj` directory.
                continue
            }
            roots.append(ScanRoot(url: entry, category: .languageFiles))
            // We tagged the whole `.lproj` as a junk root; no need to
            // descend into its contents looking for nested `.lproj`s, and
            // doing so would double-count files when FileScanner walks
            // this root afterwards.
            enumerator.skipDescendants()
        }
        return roots
    }

    /// Extracts the lower-cased language code from a locale name. Handles
    /// BCP-47 (`en-US`), underscore-separated (`zh_CN`), and the legacy
    /// English-name forms (`English`, `Spanish`). Returns `nil` for names
    /// that don't look like a locale at all (e.g. someone created a
    /// `Base.lproj` — keep those out of the active-match comparison so they
    /// fall through unchanged into the result).
    static func languageCode(fromLocaleName name: String) -> String? {
        let lowered = name.lowercased()
        if let mapped = legacyLanguageNames[lowered] {
            return mapped
        }
        // Split on either `-` or `_` and take the first component. Both
        // separators show up in `.lproj` names (`en-US`, `zh_CN`).
        let scalars = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = scalars.first else { return nil }
        // Common pseudo-locales to ignore — `Base.lproj` is bundle metadata,
        // not a language. Returning nil keeps it from matching active codes
        // and from being reported as junk.
        if first == "base" { return nil }
        return String(first)
    }
}
