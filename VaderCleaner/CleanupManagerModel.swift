// CleanupManagerModel.swift
// Shared section/category/file model for the three-pane Cleanup Manager, used by both the standalone Cleanup Review and Smart Scan's junk Review so the two screens stay identical.

import Foundation

/// Builds the `ManagerSection` model the `SmartScanReviewManager` renders for
/// junk results. The left-pane grouping mirrors the reference Cleanup Manager:
/// **System Junk** is the umbrella for every cache / log / developer-junk
/// category, while **Mail Attachments** and **Trash Bins** stand alone.
enum CleanupManagerModel {

    /// Left-pane groupings, in display order. Each group lists the
    /// `ScanCategory` values that roll up under it; categories with no findings
    /// are dropped from the built model.
    static let groups: [(id: String, title: String, categories: [ScanCategory])] = [
        (
            "systemJunk",
            String(localized: "System Junk", comment: "Cleanup Manager section grouping caches, logs, and developer junk."),
            [.userCache, .xcodeJunk, .webDevJunk, .userLogs, .documentVersions, .systemCache, .systemLogs, .languageFiles, .iosBackups]
        ),
        (
            "mailAttachments",
            String(localized: "Mail Attachments", comment: "Cleanup Manager section for mail attachment files."),
            [.mailAttachments]
        ),
        (
            "trashBins",
            String(localized: "Trash Bins", comment: "Cleanup Manager section for the trash bins."),
            [.trash]
        ),
    ]

    /// The id of the left-pane section that contains `category`, for deep
    /// linking a dashboard card's "Review" to the right place.
    static func sectionID(containing category: ScanCategory) -> String? {
        groups.first { $0.categories.contains(category) }?.id
    }

    /// One-line explanation shown as the middle pane's header for a section.
    nonisolated static func sectionDescription(forID id: String) -> String? {
        switch id {
        case "systemJunk":
            return String(localized: "Redundant files that clog up device storage and impede optimal performance.",
                          comment: "Cleanup Manager System Junk section description.")
        case "mailAttachments":
            return String(localized: "Local copies of email attachments Mail downloaded, which you can safely remove.",
                          comment: "Cleanup Manager Mail Attachments section description.")
        case "trashBins":
            return String(localized: "Items in your Trash that still use disk space until the Trash is emptied.",
                          comment: "Cleanup Manager Trash Bins section description.")
        default:
            return nil
        }
    }

    /// One-line explanation shown as the right pane's header for a category —
    /// what the files are and whether they're safe to remove.
    nonisolated static func categoryDescription(for category: ScanCategory) -> String? {
        switch category {
        case .userCache:
            return String(localized: "Cache files your apps create to load faster. They're rebuilt automatically, so they're safe to remove.",
                          comment: "Cleanup Manager User Caches category description.")
        case .systemCache:
            return String(localized: "Caches macOS writes to speed up the system. They're rebuilt as needed, so they're safe to remove.",
                          comment: "Cleanup Manager System Caches category description.")
        case .userLogs:
            return String(localized: "Diagnostic logs your apps write. Safe to remove — new ones are created as needed.",
                          comment: "Cleanup Manager User Logs category description.")
        case .systemLogs:
            return String(localized: "Diagnostic logs macOS writes. Safe to remove — the system creates new ones as needed.",
                          comment: "Cleanup Manager System Logs category description.")
        case .languageFiles:
            return String(localized: "Translations for languages you don't use, bundled inside apps. Safe to remove — your active languages and English are kept.",
                          comment: "Cleanup Manager Language Files category description.")
        case .mailAttachments:
            return String(localized: "Local copies of email attachments downloaded by Mail. Safe to remove — you can re-download them from the original messages.",
                          comment: "Cleanup Manager Mail Attachments category description.")
        case .iosBackups:
            return String(localized: "Backups of your iPhone and iPad stored on this Mac. Not rebuilt — remove only if you have another backup.",
                          comment: "Cleanup Manager iOS Backups category description.")
        case .xcodeJunk:
            return String(localized: "Derived data, archives, and old device support left behind by Xcode. Derived data and device support rebuild on demand; archives are your saved builds, so review those before removing.",
                          comment: "Cleanup Manager Xcode Junk category description.")
        case .documentVersions:
            return String(localized: "Earlier revisions macOS keeps so you can “Revert To” previous versions of documents. Removing them clears that history.",
                          comment: "Cleanup Manager Document Versions category description.")
        case .webDevJunk:
            return String(localized: "Dependency folders, build output, and package-manager caches left by web and dev toolchains. Rebuilt on demand — node_modules and build folders return after the next install or build.",
                          comment: "Cleanup Manager Web Development Junk category description.")
        case .trash:
            return String(localized: "Items you've already moved to the Trash. Cleaning them empties the Trash to reclaim the space.",
                          comment: "Cleanup Manager Trash category description.")
        case .largeFile, .oldFile:
            return nil
        }
    }

    /// SF Symbol for each junk category's middle-pane row (the fallback when no
    /// badge artwork is available).
    nonisolated static func icon(for category: ScanCategory) -> String {
        switch category {
        case .systemCache:      return "internaldrive"
        case .userCache:        return "clock.arrow.circlepath"
        case .systemLogs:       return "doc.text.magnifyingglass"
        case .userLogs:         return "doc.text"
        case .languageFiles:    return "globe"
        case .mailAttachments:  return "paperclip"
        case .iosBackups:       return "iphone"
        case .trash:            return "trash"
        case .xcodeJunk:        return "hammer"
        case .documentVersions: return "doc.on.doc"
        case .webDevJunk:       return "shippingbox"
        case .largeFile, .oldFile: return "doc"
        }
    }

    /// Glossy 3D badge asset for each category's middle-pane row — the same
    /// "Smart Care" artwork family as the dashboard. Caches reuse the clock
    /// badge, logs share one doc badge, and the rest map to their own.
    nonisolated static func badgeAsset(for category: ScanCategory) -> String {
        switch category {
        case .userCache, .systemCache: return "scanBadgeCleanupSystemJunk"
        case .userLogs, .systemLogs:   return "scanBadgeLogs"
        case .languageFiles:           return "scanBadgeLanguageFiles"
        case .iosBackups:              return "scanBadgeIosBackups"
        case .mailAttachments:         return "scanBadgeMailAttachments"
        case .trash:                   return "scanBadgeTrash"
        case .xcodeJunk:               return "scanBadgeXcodeJunk"
        case .documentVersions:        return "scanBadgeDocumentVersions"
        case .webDevJunk:              return "scanBadgeWebDevJunk"
        case .largeFile, .oldFile:     return "scanBadgeSystemJunk"
        }
    }

    /// Builds the section model off the main actor. Pure and `nonisolated`, over
    /// `Sendable` inputs, so it can run on a background task. Each category's
    /// files are pre-sorted by size (the manager's default order) with a
    /// precomputed size string, so neither the build's caller nor scrolling
    /// touches the main thread for sorting or formatting.
    ///
    /// When `includeEmptySections` is `true`, every group appears even with no
    /// findings (its detail pane shows the empty state) — the standalone Cleanup
    /// Manager always lists System Junk / Mail Attachments / Trash Bins. Smart
    /// Scan passes `false` to hide groups it found nothing for.
    ///
    /// When `hierarchical` is `true`, each category's files are folded into a
    /// one-level-expandable folder tree (top-level folders, each disclosing its
    /// immediate children) — the standalone Cleanup Manager. Smart Scan passes
    /// `false` for the historical flat leaf-file list.
    nonisolated static func build(
        itemsByCategory: [ScanCategory: [ScannedFile]],
        sizeByCategory: [ScanCategory: Int64],
        includeEmptySections: Bool,
        hierarchical: Bool
    ) -> [ManagerSection] {
        groups.compactMap { group in
            let categories = group.categories.compactMap { category -> ManagerCategory? in
                guard let files = itemsByCategory[category], !files.isEmpty else { return nil }
                let items = hierarchical ? buildHierarchy(files) : flatItems(files)
                let total = sizeByCategory[category] ?? files.reduce(0) { $0 + $1.size }
                return ManagerCategory(
                    id: category.rawValue,
                    title: category.displayName,
                    systemImage: icon(for: category),
                    tint: .green,
                    badgeAsset: badgeAsset(for: category),
                    items: items,
                    totalSize: total,
                    totalSizeText: ManagerByteText.string(total),
                    description: categoryDescription(for: category)
                )
            }
            if categories.isEmpty && !includeEmptySections { return nil }
            return ManagerSection(
                id: group.id,
                title: group.title,
                categories: categories,
                description: sectionDescription(forID: group.id)
            )
        }
    }

    /// Builds just the section/category *shell* — the left and middle panes —
    /// with each category's size and badge but **no items**. Cheap (no file-tree
    /// walking), so the manager can paint its panes immediately and fill each
    /// category's rows lazily via `items(forCategory:in:)`.
    nonisolated static func buildShell(
        itemsByCategory: [ScanCategory: [ScannedFile]],
        sizeByCategory: [ScanCategory: Int64],
        includeEmptySections: Bool
    ) -> [ManagerSection] {
        groups.compactMap { group in
            let categories = group.categories.compactMap { category -> ManagerCategory? in
                guard let files = itemsByCategory[category], !files.isEmpty else { return nil }
                let total = sizeByCategory[category] ?? files.reduce(0) { $0 + $1.size }
                return ManagerCategory(
                    id: category.rawValue,
                    title: category.displayName,
                    systemImage: icon(for: category),
                    tint: .green,
                    badgeAsset: badgeAsset(for: category),
                    items: [],
                    totalSize: total,
                    totalSizeText: ManagerByteText.string(total),
                    description: categoryDescription(for: category)
                )
            }
            if categories.isEmpty && !includeEmptySections { return nil }
            return ManagerSection(
                id: group.id,
                title: group.title,
                categories: categories,
                description: sectionDescription(forID: group.id)
            )
        }
    }

    /// The rows for a single category — the right pane's contents. Built on
    /// demand so opening the manager never walks every category.
    nonisolated static func items(
        forCategory category: ScanCategory,
        in itemsByCategory: [ScanCategory: [ScannedFile]]
    ) -> [ManagerItem] {
        buildItems(for: category, files: itemsByCategory[category] ?? [])
    }

    /// A category's rows: Web Development Junk names its project artifacts
    /// individually, every other category folds into the folder hierarchy.
    nonisolated static func buildItems(
        for category: ScanCategory,
        files: [ScannedFile],
        cacheRoots: [String] = WebDevArtifact.packageCacheRoots
    ) -> [ManagerItem] {
        guard category == .webDevJunk else { return buildHierarchy(files) }
        return webDevItems(files, cacheRoots: cacheRoots)
    }

    /// The rows for Web Development Junk together with the project artifacts
    /// that count as idle — both products of the single expensive pass that
    /// separates package-cache files from per-project artifacts. Computed once,
    /// off the main thread (see `CleanupManagerStore`), because that separation
    /// walks every file in the category and `~/.npm` alone reaches a third of a
    /// million of them.
    struct WebDevContent: Sendable {
        let items: [ManagerItem]
        let idleProjectFiles: [ScannedFile]
    }

    /// Splits `files` into package caches and per-project artifacts once, then
    /// builds both the rows and the idle-project list from that split. The
    /// package caches keep the folder tree — `~/.npm` is one row, not its
    /// hundreds of thousands of files — while each per-project artifact folder
    /// gets its own row titled with the project it belongs to, so a glance
    /// answers "am I about to lose my repository?" without disclosing two levels.
    ///
    /// The isProjectArtifact test runs per file over the whole category, so this
    /// must never run on the main thread (it did, via the Select menu, and cost
    /// ~0.5 s per pass on a large `.npm`).
    nonisolated static func webDevContent(
        _ files: [ScannedFile],
        now: Date = Date(),
        cacheRoots: [String] = WebDevArtifact.packageCacheRoots
    ) -> WebDevContent {
        var caches: [ScannedFile] = []
        var projects: [ScannedFile] = []
        for file in files {
            if WebDevArtifact.isProjectArtifact(file.url, cacheRoots: cacheRoots) {
                projects.append(file)
            } else {
                caches.append(file)
            }
        }
        let projectRows = projects.map { file in
            ManagerItem(
                id: file.url.path,
                title: WebDevArtifact.rowTitle(for: file.url),
                subtitle: WebDevArtifact.rowSubtitle(for: file, now: now),
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: "folder.fill",
                tint: .blue,
                usesFileIcon: true,
                selectionPaths: [file.url.path]
            )
        }
        return WebDevContent(
            items: (buildHierarchy(caches) + projectRows).sorted { ($0.size ?? 0) > ($1.size ?? 0) },
            idleProjectFiles: projects.filter { WebDevArtifact.isIdle($0, now: now) }
        )
    }

    /// Web Development Junk rows only — the common case, when the idle list
    /// isn't needed. Delegates to the single-pass `webDevContent`.
    nonisolated static func webDevItems(
        _ files: [ScannedFile],
        now: Date = Date(),
        cacheRoots: [String] = WebDevArtifact.packageCacheRoots
    ) -> [ManagerItem] {
        webDevContent(files, now: now, cacheRoots: cacheRoots).items
    }

    /// Extra bulk-select picks for a category's "Select:" menu, beyond Select
    /// All / Deselect All.
    ///
    /// Web Development Junk gets one: check exactly the project artifacts that
    /// have sat untouched past `WebDevArtifact.idleThreshold`. Age is the one
    /// signal that separates the dependencies of a project shipping tomorrow
    /// from those of one abandoned last year, and it's the only bulk judgement
    /// a user can make without weighing each project. The pick clears the
    /// category first (`clearAll`), so it's an exact selection rather than an
    /// addition to whatever was already checked. Absent when nothing qualifies —
    /// an option that would select nothing is worse than no option.
    ///
    /// `idleProjectFiles` is precomputed off-main (`webDevContent`) and passed
    /// in, so this — which runs in the SwiftUI body every time the menu is
    /// built — stays O(1) and never rescans the category.
    nonisolated static func selectFilters(
        forCategoryID id: String,
        idleProjectFiles: [ScannedFile],
        clearAll: @escaping () -> Void,
        selectIdle: @escaping ([ScannedFile]) -> Void
    ) -> [ManagerSelectFilter] {
        guard id == ScanCategory.webDevJunk.rawValue, !idleProjectFiles.isEmpty else { return [] }
        return [ManagerSelectFilter(
            id: "webDevJunk.idleProjects",
            title: String(
                localized: "Select Idle Projects",
                comment: "Bulk-select entry checking only long-untouched project build artifacts."
            ),
            apply: {
                clearAll()
                selectIdle(idleProjectFiles)
            }
        )]
    }

    /// The historical flat list: one leaf row per scanned file, size-sorted.
    private nonisolated static func flatItems(_ files: [ScannedFile]) -> [ManagerItem] {
        files.sorted { $0.size > $1.size }.map { file in
            let isDirectory = file.url.pathExtension.isEmpty
            return ManagerItem(
                id: file.url.path,
                title: file.url.lastPathComponent,
                subtitle: file.url.deletingLastPathComponent().path,
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: isDirectory ? "folder.fill" : "doc.fill",
                tint: isDirectory ? .blue : .secondary,
                usesFileIcon: true
            )
        }
    }

    /// Folds a category's flat file list into a one-level-expandable tree: the
    /// top-level rows are the immediate children of the files' common ancestor
    /// directory (e.g. the per-app folders under `~/Library/Caches`), and each
    /// folder discloses its own immediate children. Every node aggregates the
    /// sizes and paths of the scanned files beneath it. Results are size-sorted.
    nonisolated static func buildHierarchy(_ files: [ScannedFile]) -> [ManagerItem] {
        guard !files.isEmpty else { return [] }
        let ancestorDepth = commonPrefixCount(files.map { $0.url.pathComponents })
        return groupedNodes(files, depth: ancestorDepth, indentLevel: 0, expandChildren: true)
    }

    /// Groups `files` by their path component at `depth` into sibling nodes.
    private nonisolated static func groupedNodes(
        _ files: [ScannedFile],
        depth: Int,
        indentLevel: Int,
        expandChildren: Bool
    ) -> [ManagerItem] {
        var order: [String] = []
        var groups: [String: [ScannedFile]] = [:]
        for file in files {
            let comps = file.url.pathComponents
            guard comps.count > depth else { continue }
            let key = comps[depth]
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        return order
            .map { key in node(key, files: groups[key]!, depth: depth, indentLevel: indentLevel, expandChildren: expandChildren) }
            .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    /// Builds a single node whose name is the component at `depth`, aggregating
    /// `files`. A node with files deeper than `depth + 1` is a folder; when
    /// `expandChildren` is set it gets one level of children (which are
    /// themselves leaves — one level of expansion only).
    private nonisolated static func node(
        _ name: String,
        files: [ScannedFile],
        depth: Int,
        indentLevel: Int,
        expandChildren: Bool
    ) -> ManagerItem {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let nodePath = NSString.path(withComponents: Array(files[0].url.pathComponents[0...depth]))
        let hasDeeper = files.contains { $0.url.pathComponents.count > depth + 1 }
        let children = (expandChildren && hasDeeper)
            ? groupedNodes(files, depth: depth + 1, indentLevel: indentLevel + 1, expandChildren: false)
            : []
        // Only childless nodes carry the paths they cover. An expandable folder
        // delegates to its children (the store unions them on demand), so a
        // file's path isn't copied once per ancestor level — over hundreds of
        // thousands of files that per-level duplication dominated the manager's
        // memory footprint. The children partition the folder's files exactly,
        // so unioning them reconstructs the folder's full set.
        let selectionPaths = children.isEmpty ? files.map { $0.url.path } : []
        return ManagerItem(
            id: nodePath,
            title: name,
            subtitle: nil,
            size: total,
            sizeText: ManagerByteText.string(total),
            systemImage: hasDeeper ? "folder.fill" : "doc.fill",
            tint: .blue,
            usesFileIcon: true,
            children: children,
            indentLevel: indentLevel,
            selectionPaths: selectionPaths
        )
    }

    /// Number of leading path components shared by every file, capped so at
    /// least one component remains below the ancestor for the shortest path
    /// (otherwise a file could become its own ancestor).
    private nonisolated static func commonPrefixCount(_ lists: [[String]]) -> Int {
        guard let first = lists.first else { return 0 }
        let minLen = lists.map(\.count).min() ?? 0
        var count = 0
        outer: for index in 0..<minLen {
            let component = first[index]
            for list in lists where list[index] != component { break outer }
            count = index + 1
        }
        return max(0, min(count, minLen - 1))
    }
}
