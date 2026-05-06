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

    /// Cap on how deep we'll *descend* (into non-`.lproj` directories) when
    /// walking a scan root. The cap is a perf bound to keep us out of
    /// binary asset trees inside packages, not a filter on matches —
    /// `.lproj` directories are always processed when we encounter them,
    /// regardless of depth (see `lprojRoots(under:)`).
    ///
    /// Depths to plan for, measured from a top-level scan root like
    /// `/Applications`:
    ///   - `Foo.app/Contents/Resources/<lang>.lproj` → depth 4
    ///   - `Foo.app/Contents/Frameworks/Bar.framework/Resources/...` → depth 6
    ///   - `Foo.app/Contents/PlugIns/Bar.appex/Contents/Resources/...` → depth 7
    ///   - Versioned frameworks inside extensions → depth 9–10
    /// A cap of 10 lets the walker descend through the deepest realistic
    /// nesting (extension-inside-app or versioned framework) without
    /// expanding into every nested `.bundle` of subassets. Reported by
    /// Codex on PR #28: prior cap of 6 missed `.appex` extension lprojs.
    private static let maxLprojWalkDepth = 10

    /// Builds the `[ScanRoot]` for a single top-level directory. Pulled out
    /// so each root is independently failure-tolerant: an unreadable
    /// `/Library/Frameworks` doesn't prevent us from walking `/Applications`.
    /// The walk is depth-bounded — see `maxLprojWalkDepth` — to keep `.app`
    /// bundles from making this O(every-file-under-/Applications).
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
            // Match on `.lproj` first — *before* the depth cap. The cap is
            // a perf bound on descent into non-matching subtrees; it must
            // not also prune valid matches at the same depth (e.g. an
            // `.appex` extension's `.lproj` at depth 7).
            if entry.pathExtension.caseInsensitiveCompare("lproj") == .orderedSame {
                let localeName = entry.deletingPathExtension().lastPathComponent
                if let code = Self.languageCode(fromLocaleName: localeName),
                   !activeLanguageCodes.contains(code) {
                    roots.append(ScanRoot(url: entry, category: .languageFiles))
                }
                // Always skip the contents of an `.lproj`. For a non-active
                // match we tagged the whole directory as the junk root, so
                // descending would double-count when FileScanner walks it
                // later. For an active or skipped (`Base`/unmapped legacy)
                // match we don't expect nested `.lproj`s and don't want to
                // pay the descent cost either.
                enumerator.skipDescendants()
                continue
            }

            // Non-`.lproj` directory at or past the cap: stop descending
            // further down this branch but keep walking siblings.
            if enumerator.level > Self.maxLprojWalkDepth {
                enumerator.skipDescendants()
            }
        }
        return roots
    }

    /// Extracts the lower-cased language code from a locale name. Handles
    /// BCP-47 (`en-US`), underscore-separated (`zh_CN`), and the legacy
    /// English-name forms (`English`, `Spanish`) listed in
    /// `legacyLanguageNames`. Returns `nil` when the name should be skipped
    /// entirely — callers (`lprojRoots(under:)`) drop nil-coded entries
    /// from the result, so neither `Base.lproj` nor unmapped legacy names
    /// like `Portuguese` are ever reported as junk.
    ///
    /// Conservative skip rule for unmapped legacy names: a single-token
    /// name (no `-` or `_`) longer than 3 characters that isn't in the
    /// allowlist is skipped. ISO 639-1/-2 codes are 2–3 chars, so this
    /// preserves `nl`/`eng` while rejecting `Portuguese`/`Norwegian`.
    /// Without this, `Portuguese.lproj` returned `"portuguese"` — never a
    /// match for active BCP-47 `pt`, so the user's *active* locale
    /// resources got reported as junk. Reported by Codex review on PR #28.
    static func languageCode(fromLocaleName name: String) -> String? {
        let lowered = name.lowercased()
        if let mapped = legacyLanguageNames[lowered] {
            return mapped
        }
        // Split on either `-` or `_` and take the first component. Both
        // separators show up in `.lproj` names (`en-US`, `zh_CN`).
        let parts = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first.map(String.init) else { return nil }
        // Pseudo-locale ignored explicitly — `Base.lproj` is bundle
        // metadata, not a language.
        if first == "base" { return nil }
        // Single-token name longer than an ISO code is almost certainly a
        // legacy English-style name we don't have an allowlist entry for
        // (e.g. `Portuguese`, `Norwegian`). Returning nil here means the
        // caller drops the entry — safer than emitting a code that will
        // never match an active locale and risking deletion of the user's
        // active resources.
        if parts.count == 1 && first.count > 3 {
            return nil
        }
        return first
    }
}
