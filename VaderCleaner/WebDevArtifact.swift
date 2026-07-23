// WebDevArtifact.swift
// Tells the two kinds of Web Development Junk finding apart — shared package-manager cache files versus per-project build artifacts — and supplies the row copy and idle-age rule the per-project ones are presented with.

import Foundation

/// Classification and presentation rules for `.webDevJunk` findings.
///
/// The category holds two kinds of file with very different costs. Package
/// manager caches (`~/.npm`, `~/.pnpm-store`, …) are shared across every
/// project and re-download on demand, so losing one costs bandwidth. Per
/// project artifacts (`node_modules`, `dist`, `target`, …) are rolled up one
/// folder per finding by `DeveloperProjectScanner`, and losing one costs *that
/// project* a full reinstall or rebuild the next time it's opened.
///
/// Everything that has to treat the two differently — the manager's rows, the
/// safe-by-default selection, the idle-projects bulk pick — asks here, so the
/// split is defined once.
enum WebDevArtifact {

    /// How long a project artifact must sit untouched to count as idle. Long
    /// enough that a rebuild is unlikely to be missed, short enough to still
    /// cover most of a cluttered code folder.
    static let idleThreshold: TimeInterval = 90 * 24 * 60 * 60

    /// The package-manager cache roots on this Mac, in both their plain and
    /// symlink-resolved forms. Everything in `.webDevJunk` that isn't under one
    /// of these came from the project walk.
    ///
    /// Both forms are kept so membership can be answered by string comparison
    /// against a scanned file's own path: canonicalizing each *file* instead
    /// would resolve symlinks — a filesystem round trip — once per finding, and
    /// this runs over every cached file in a category that reaches hundreds of
    /// thousands of them.
    static let packageCacheRoots: [String] = {
        let roots = DefaultSystemPathProvider
            .webDevCacheRoots(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        var forms: [String] = []
        for root in roots {
            for form in [root.path, PathExclusionMatcher.canonicalize(root)] where !forms.contains(form) {
                forms.append(form)
            }
        }
        return forms
    }()

    /// Whether a finding is a per-project artifact folder rather than a file
    /// inside a shared package cache. Matching is at path-component boundaries
    /// (via `PathExclusionMatcher`), so a `~/.npmrc-backup` is not mistaken for
    /// part of `~/.npm`.
    static func isProjectArtifact(_ url: URL, cacheRoots: [String] = packageCacheRoots) -> Bool {
        !PathExclusionMatcher.isExcluded(path: url.path, by: cacheRoots)
    }

    /// "pixel-prompt / node_modules" — the project and the folder that will be
    /// removed from it. The artifact folder alone ("node_modules") doesn't say
    /// which project pays for its removal, and the project alone reads like the
    /// repository itself is at stake.
    static func rowTitle(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/" else { return url.lastPathComponent }
        return String.localizedStringWithFormat(
            String(
                localized: "%@ / %@",
                comment: "Web Development Junk row title: containing project folder, artifact folder."
            ),
            parent, url.lastPathComponent
        )
    }

    /// "Last changed 8 months ago · /Users/me/Developer/pixel-prompt" — how
    /// stale the artifact is and which project it belongs to, the two facts
    /// behind keeping or removing it. Falls back to the containing folder alone
    /// when the volume reports no timestamps, rather than inventing an age.
    static func rowSubtitle(for file: ScannedFile, now: Date = Date()) -> String {
        let folder = file.url.deletingLastPathComponent().path
        guard let changed = lastChanged(file) else { return folder }
        return String.localizedStringWithFormat(
            String(
                localized: "Last changed %@ · %@",
                comment: "Web Development Junk row subtitle: relative last-changed date, containing project folder."
            ),
            relativeFormatter.localizedString(for: changed, relativeTo: now), folder
        )
    }

    /// Whether an artifact has sat untouched past `idleThreshold`. A finding
    /// with no timestamps is never idle — an unknown date is not evidence of
    /// disuse, and a bulk pick must not sweep one up.
    static func isIdle(_ file: ScannedFile, now: Date = Date()) -> Bool {
        guard let changed = lastChanged(file) else { return false }
        return now.timeIntervalSince(changed) >= idleThreshold
    }

    /// Modification time is the "did anyone work on this" signal; access time
    /// only stands in when it's missing, since walking a folder can refresh it
    /// and make every artifact look fresh.
    private static func lastChanged(_ file: ScannedFile) -> Date? {
        file.lastModifiedDate ?? file.lastAccessDate
    }

    /// Shared formatter — construction is expensive and the row builder runs it
    /// once per artifact.
    private static let relativeFormatter = RelativeDateTimeFormatter()
}
