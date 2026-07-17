// MyClutterManagerView.swift
// The "Review All Files" screen: a white-card, three-pane My Clutter Manager (categories → groups/facets → files/preview) styled after the Cleanup Manager, with a large image preview for photo categories and browser icons for downloads.

import SwiftUI
import AppKit

/// Three-pane review over every My Clutter category. The left pane lists the
/// four categories; the middle pane shows that category's groups or facets; the
/// right pane shows the files, or — for the image categories — a large preview
/// with a thumbnail strip and metadata. Selection and removal route through the
/// shared `MyClutterViewModel`.
struct MyClutterManagerView: View {
    @Bindable var viewModel: MyClutterViewModel
    /// Category to open on first show, for deep-linking from a dashboard card.
    var initialCategory: MyClutterCategory = .largeOld
    let onBack: () -> Void

    /// The reference Manager uses a magenta accent on a white surface — the same
    /// one the Cleanup Manager adopts — independent of the section's teal.
    static let accent = Color(red: 0.81, green: 0.10, blue: 0.55)

    @State private var category: MyClutterCategory
    @State private var search = ""
    @State private var sort: ManagerSort = .size

    // Per-category middle-pane selection.
    @State private var largeOldFacet: MyClutterLargeOldFacet = .all
    @State private var selectedGroupID: String?
    @State private var selectedBrowser: String?
    // Focused file in the image-preview pane, and a lazy creation-date cache.
    @State private var focusedURL: URL?
    @State private var creationDates: [URL: Date] = [:]

    // Off-main caches of the expensive derived data, rebuilt only when the
    // result set changes — never on a selection toggle. Without these the
    // facet sums, sorts, and groupings recompute on every render and beach-ball.
    @State private var largeOldCache = LargeOldFacetCache()
    @State private var downloadCache: [MyClutterDownloadGroup] = []
    /// True while the off-main caches are (re)building, so the cache-backed
    /// panes show a loader instead of a momentarily-empty list.
    @State private var isLoadingCache = false

    /// The right pane's rendered file rows, memoized so a selection toggle
    /// re-renders the checkboxes without re-running the search filter (and,
    /// under name sort, the O(n log n) re-sort) over the whole facet on every
    /// render. Rebuilt off the main actor only when a real input changes —
    /// see `DisplayInputs`.
    @State private var displayedFiles: [ScannedFile] = []

    /// Most file rows rendered at once. The lists are pre-sorted, so the capped
    /// slice is the meaningful top; the rest is reached by clearing and re-scanning.
    private static let displayRowLimit = 1000

    init(viewModel: MyClutterViewModel, initialCategory: MyClutterCategory = .largeOld, onBack: @escaping () -> Void) {
        self.viewModel = viewModel
        self.initialCategory = initialCategory
        self.onBack = onBack
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                categoryPane.frame(width: 240)
                Divider().opacity(0.4)
                middlePane.frame(width: 320)
                Divider().opacity(0.4)
                rightPane.frame(maxWidth: .infinity)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(14)
        // The title-bar safe-area extension is applied by MyClutterView,
        // outside the manager zoom transition — see ManagerSurfaceModifier.
        .tint(Self.accent)
        .environment(\.sectionAccent, Self.accent)
        .accessibilityIdentifier("myClutter.manager")
        // Rebuild the derived caches off the main actor whenever the result set
        // changes (and on first appearance). Selection toggles bump nothing
        // here, so they no longer trigger an O(N) recompute.
        .task(id: viewModel.resultsVersion) { await rebuildCaches() }
        // Rebuild the right pane's rows only when a display input changes.
        // The selection stamp participates only under the "Selected" facet,
        // so an ordinary checkbox toggle repaints rows without recomputing
        // the list.
        .task(id: displayInputs) { await rebuildDisplayedFiles() }
    }

    /// The complete set of inputs the right pane's file rows derive from. The
    /// rebuild task keys on this value, so any change reruns it and everything
    /// else (notably a selection toggle outside the "Selected" facet) does not.
    private struct DisplayInputs: Equatable {
        let category: MyClutterCategory
        let facet: MyClutterLargeOldFacet
        let browser: String?
        let search: String
        let sort: ManagerSort
        let resultsVersion: Int
        let cacheLoading: Bool
        /// Selected-file count in Large & Old — an O(1) read that changes on
        /// every relevant toggle. Pinned to 0 outside the "Selected" facet so
        /// toggles there don't retrigger the rebuild.
        let selectionStamp: Int
    }

    private var displayInputs: DisplayInputs {
        DisplayInputs(
            category: category,
            facet: largeOldFacet,
            browser: selectedBrowser,
            search: search,
            sort: sort,
            resultsVersion: viewModel.resultsVersion,
            cacheLoading: isLoadingCache,
            selectionStamp: (category == .largeOld && largeOldFacet == .selected)
                ? viewModel.selectedCount(in: .largeOld)
                : 0
        )
    }

    /// Recomputes `displayedFiles` off the main actor: picks the pre-sorted
    /// base list for the active category/facet, applies the "Selected" filter
    /// when that facet is active, then runs the shared search/sort/cap pass.
    private func rebuildDisplayedFiles() async {
        let base: [ScannedFile]
        var selection: Set<URL>? = nil
        switch category {
        case .largeOld:
            switch largeOldFacet {
            case .all:
                base = largeOldCache.allSorted
            case .selected:
                base = largeOldCache.allSorted
                selection = viewModel.selectedURLs
            case .kind(let kind):
                base = largeOldCache.byKind[kind] ?? []
            case .size(let bucket):
                base = largeOldCache.bySize[bucket] ?? []
            }
        case .downloads:
            let group = downloadCache.first(where: { $0.source == selectedBrowser }) ?? downloadCache.first
            base = group?.items.map(\.file) ?? []
        case .duplicates, .similar:
            // The image categories render the preview pane, not a file list.
            displayedFiles = []
            return
        }
        let search = self.search
        let sortByName = sort == .name
        let limit = Self.displayRowLimit
        let selectionFilter = selection
        let rows = await Task.detached(priority: .userInitiated) {
            var files = base
            if let selectionFilter {
                files = files.filter { selectionFilter.contains($0.url) }
            }
            return MyClutterManagerModel.display(files, search: search, sortByName: sortByName, limit: limit)
        }.value
        // A superseded rebuild (its `.task` id changed mid-flight) must not
        // overwrite the newer task's rows.
        guard !Task.isCancelled else { return }
        displayedFiles = rows
    }

    private func rebuildCaches() async {
        isLoadingCache = true
        let files = viewModel.largeOldFiles
        let downloads = viewModel.downloads
        let cache = await Task.detached(priority: .userInitiated) {
            LargeOldFacetCache(files: files)
        }.value
        let groups = await Task.detached(priority: .userInitiated) {
            MyClutterManagerModel.downloadsBySource(downloads)
        }.value
        largeOldCache = cache
        downloadCache = groups
        isLoadingCache = false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").foregroundStyle(.tint)
                    Text(String(localized: "Back", comment: "Back button on the My Clutter Manager."))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("myClutter.manager.back")

            Spacer()
            Text(String(localized: "My Clutter Manager", comment: "My Clutter Manager screen title."))
                .font(.headline)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tint)
                TextField(String(localized: "Search", comment: "Manager search placeholder."), text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 130)
            }

            Menu {
                ForEach(ManagerSort.allCases) { option in
                    Button(option.label) { sort = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "Sort by:", comment: "Manager sort label.")).foregroundStyle(.secondary)
                    Text(sort.label).foregroundStyle(.tint)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Left pane (categories)

    private var categoryPane: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(MyClutterCategory.allCases) { item in
                    NavRow(selected: item == category) {
                        category = item
                        resetMiddleSelection()
                    } content: {
                        Text(item.title)
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("myClutter.manager.category.\(item.rawValue)")
                }
            }
            .padding(8)
        }
    }

    // MARK: - Middle pane

    @ViewBuilder
    private var middlePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(title: category.title, description: category.blurb)
            ScrollView {
                switch category {
                case .largeOld: largeOldFacets
                case .duplicates: groupList(viewModel.duplicateGroups.map { ($0.id, $0.original, $0.files) })
                case .similar: groupList(viewModel.similarGroups.map { ($0.id, $0.original, $0.files) })
                case .downloads: browserList
                }
            }
        }
    }

    /// The Large & Old facet list: All Files / Selected, then By Kind and By Size.
    /// All sizes come from the precomputed cache; "Selected" is an O(1) read of
    /// the view-model's incrementally-maintained per-category total, rather than
    /// a per-render pass over the (potentially huge) cached list.
    private var largeOldFacets: some View {
        let selectedBytes = viewModel.selectedBytes(in: .largeOld)
        return VStack(spacing: 4) {
            facetRow(.all, label: String(localized: "All Files", comment: "Large & Old facet."), bytes: largeOldCache.bytesAll)
            facetRow(.selected, label: String(localized: "Selected", comment: "Large & Old facet."), bytes: selectedBytes)

            facetSectionHeader(String(localized: "By Kind", comment: "Large & Old facet group header."))
            ForEach(MyClutterFileKind.allCases, id: \.self) { kind in
                facetRow(.kind(kind), label: kind.title, bytes: largeOldCache.bytesByKind[kind] ?? 0)
            }

            facetSectionHeader(String(localized: "By Size", comment: "Large & Old facet group header."))
            ForEach(MyClutterSizeBucket.allCases, id: \.self) { bucket in
                facetRow(.size(bucket), label: bucket.title, bytes: largeOldCache.bytesBySize[bucket] ?? 0)
            }
        }
        .padding(8)
    }

    private func facetRow(_ facet: MyClutterLargeOldFacet, label: String, bytes: Int64) -> some View {
        NavRow(selected: largeOldFacet == facet) {
            largeOldFacet = facet
        } content: {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text(ManagerByteText.string(bytes))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func facetSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    /// Group list for Duplicates / Similar Images: a representative thumbnail,
    /// the group name, its reclaimable size, and a copy count badge.
    private func groupList(_ groups: [(id: String, original: ScannedFile, files: [ScannedFile])]) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(groups, id: \.id) { group in
                NavRow(selected: selectedGroupID == group.id) {
                    selectedGroupID = group.id
                    focusedURL = group.files.first?.url
                } content: {
                    HStack(spacing: 12) {
                        ClutterThumbnailView(url: group.original.url, fallbackSymbol: "photo")
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.original.url.lastPathComponent)
                                .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text(ManagerByteText.string(group.files.reduce(Int64(0)) { $0 + $1.size }))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text("\(group.files.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding(8)
    }

    /// Browser list for Downloads: the source app's real icon, its name, and size.
    private var browserList: some View {
        LazyVStack(spacing: 4) {
            ForEach(downloadCache) { group in
                NavRow(selected: selectedBrowser == group.source) {
                    selectedBrowser = group.source
                } content: {
                    HStack(spacing: 12) {
                        browserIcon(for: group)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.source).font(.body.weight(.medium)).lineLimit(1)
                            Text(ManagerByteText.string(group.bytes))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(8)
    }

    // MARK: - Right pane

    private var rightPaneHeader: (title: String, description: String)? {
        switch category {
        case .largeOld:
            switch largeOldFacet {
            case .all:
                return (
                    String(localized: "All Files", comment: "Large & Old right pane title."),
                    String(localized: "All large and old files detected on your Mac.", comment: "Large & Old right pane description.")
                )
            case .selected:
                return (
                    String(localized: "Selected", comment: "Large & Old right pane title."),
                    String(localized: "Files you have marked for removal.", comment: "Large & Old right pane description.")
                )
            case .kind(let kind):
                let desc: String
                switch kind {
                case .archives:
                    desc = String(localized: "Compressed archives, disk images, and packages.", comment: "Archives right pane description.")
                case .videos:
                    desc = String(localized: "Video files taking up space on your Mac.", comment: "Videos right pane description.")
                case .other:
                    desc = String(localized: "Large or old files that are not videos or archives.", comment: "Other right pane description.")
                }
                return (kind.title, desc)
            case .size(let bucket):
                let desc: String
                switch bucket {
                case .huge:
                    desc = String(localized: "Files larger than 5 GB.", comment: "Huge right pane description.")
                case .average:
                    desc = String(localized: "Files between 1 GB and 5 GB.", comment: "Average right pane description.")
                case .small:
                    desc = String(localized: "Files under 1 GB.", comment: "Small right pane description.")
                }
                return (bucket.title, desc)
            }
        case .duplicates:
            let id = selectedGroupID ?? viewModel.duplicateGroups.first?.id
            let title = viewModel.duplicateGroups.first(where: { $0.id == id })?.original.url.lastPathComponent
                ?? String(localized: "Duplicates", comment: "Duplicates right pane fallback title.")
            return (title, String(localized: "Identical copies stored in different places.", comment: "Duplicates right pane description."))
        case .similar:
            let id = selectedGroupID ?? viewModel.similarGroups.first?.id
            let title = viewModel.similarGroups.first(where: { $0.id == id })?.original.url.lastPathComponent
                ?? String(localized: "Similar Images", comment: "Similar right pane fallback title.")
            return (title, String(localized: "Similar images you can compare — keep the best, remove the rest.", comment: "Similar right pane description."))
        case .downloads:
            let source = selectedBrowser ?? downloadCache.first?.source
            let title = source ?? String(localized: "Downloads", comment: "Downloads right pane fallback title.")
            return (title, String(localized: "Files downloaded from the web. Remove one-time downloads to save space.", comment: "Downloads right pane description."))
        }
    }

    @ViewBuilder
    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let h = rightPaneHeader {
                paneHeader(title: h.title, description: h.description)
            }
            rightPaneContent
        }
    }

    @ViewBuilder
    private var rightPaneContent: some View {
        switch category {
        case .largeOld:
            if isLoadingCache {
                loadingPane
            } else if displayedFiles.isEmpty {
                emptyRightPane
            } else {
                fileList(displayedFiles)
            }
        case .duplicates:
            if let group = viewModel.duplicateGroups.first(where: { $0.id == (selectedGroupID ?? viewModel.duplicateGroups.first?.id) }) {
                imagePreviewPane(files: group.files, original: group.original, showsBestBadge: false)
            } else { emptyRightPane }
        case .similar:
            if let group = viewModel.similarGroups.first(where: { $0.id == (selectedGroupID ?? viewModel.similarGroups.first?.id) }) {
                imagePreviewPane(files: group.files, original: group.original, showsBestBadge: true)
            } else { emptyRightPane }
        case .downloads:
            if isLoadingCache {
                loadingPane
            } else if downloadCache.isEmpty {
                emptyRightPane
            } else {
                fileList(displayedFiles)
            }
        }
    }

    /// Centered spinner shown in the right pane while the off-main caches build.
    private var loadingPane: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .accessibilityIdentifier("myClutter.manager.loading")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyRightPane: some View {
        ManagerEmptyState(
            icon: "checkmark.seal.fill",
            title: String(localized: "Nothing to review", comment: "Empty manager pane title."),
            detail: String(localized: "There are no items to clean or fix in this area.\nEverything is in order.", comment: "Empty manager pane detail.")
        )
    }

    /// A scrollable list of file rows with a checkbox, thumbnail, name,
    /// breadcrumb path, modified date, and size.
    private func fileList(_ files: [ScannedFile]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(files, id: \.url) { file in
                    fileRow(file)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func fileRow(_ file: ScannedFile) -> some View {
        HStack(spacing: 12) {
            checkbox(for: file.url)
            ClutterThumbnailView(url: file.url, fallbackSymbol: "doc.fill")
                .frame(width: 44, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                breadcrumb(file.url)
            }
            Spacer(minLength: 8)
            SmartInsightsSparkle(itemTitle: file.url.lastPathComponent, accent: Self.accent, topic: .fileOrFolder)
            Text(dateText(file.lastModifiedDate ?? file.lastAccessDate))
                .font(.callout).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            Text(ManagerByteText.string(file.size))
                .font(.callout.weight(.semibold)).frame(width: 72, alignment: .trailing)
        }
        .padding(12)
        .managerRowCard()
    }

    /// The image-preview pane for Duplicates / Similar Images: a "Select"
    /// control, a thumbnail strip (the kept original flagged), a large preview,
    /// and the focused file's metadata.
    private func imagePreviewPane(files: [ScannedFile], original: ScannedFile, showsBestBadge: Bool) -> some View {
        let copies = files.filter { $0.url != original.url }
        let focused = files.first(where: { $0.url == focusedURL }) ?? original
        // A ScrollView (not a plain VStack) so the pane sizes like the file
        // lists: it fills the available height and scrolls if the preview +
        // metadata are taller, instead of forcing the whole white card past the
        // window edges (which hid the surrounding margin).
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text(String(localized: "Select:", comment: "Manager bulk-select label.")).foregroundStyle(.secondary)
                    Menu {
                        Button(String(localized: "All Copies", comment: "Select all removable copies.")) {
                            viewModel.setSelection(copies.map(\.url), selected: true)
                        }
                        Button(String(localized: "None", comment: "Deselect all.")) {
                            viewModel.setSelection(copies.map(\.url), selected: false)
                        }
                    } label: {
                        Text(selectLabel(for: copies)).foregroundStyle(.tint)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(files, id: \.url) { file in
                            thumbnailStripItem(file, isOriginal: file.url == original.url, showsBestBadge: showsBestBadge)
                        }
                    }
                }

                ClutterThumbnailView(url: focused.url, fallbackSymbol: "photo", pointSize: 600, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                metadata(for: focused)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func thumbnailStripItem(_ file: ScannedFile, isOriginal: Bool, showsBestBadge: Bool) -> some View {
        ClutterThumbnailStripItem(
            url: file.url,
            isOriginal: isOriginal,
            showsBestBadge: showsBestBadge,
            isSelected: viewModel.isSelected(file.url),
            isFocused: (focusedURL ?? file.url) == file.url,
            accent: Self.accent,
            onToggleSelect: { viewModel.toggleSelection(url: file.url) },
            onFocus: { focusedURL = file.url }
        )
    }

    private func metadata(for file: ScannedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.url.lastPathComponent).font(.title3.weight(.semibold))
            breadcrumb(file.url)
            metaRow(String(localized: "Modified:", comment: "Metadata label."), dateText(file.lastModifiedDate))
            metaRow(String(localized: "Created:", comment: "Metadata label."), dateText(creationDates[file.url]))
            metaRow(String(localized: "Size:", comment: "Metadata label."), ManagerByteText.string(file.size))
            metaRow(String(localized: "File type:", comment: "Metadata label."), file.url.pathExtension.uppercased())
        }
        .task(id: file.url) {
            if creationDates[file.url] == nil {
                creationDates[file.url] = (try? file.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Footer

    private var footer: some View {
        // Footer total and Remove are scoped to the category currently being
        // reviewed, so opening a card's Review shows exactly that card's
        // selection (its size matches the dashboard tile) rather than the
        // global selection across every category.
        let selection = categorySelection()
        return HStack(spacing: 12) {
            Text(footerSummary(selection)).font(.callout.weight(.medium))
                .accessibilityIdentifier("myClutter.manager.summary")
            Spacer()
            Button(String(localized: "Remove", comment: "Footer button that trashes the selected files.")) {
                Task {
                    await viewModel.deleteSelected(in: currentCategoryURLs)
                    if viewModel.totalFileCount == 0 { onBack() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selection.count == 0)
            .accessibilityIdentifier("myClutter.manager.remove")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func footerSummary(_ selection: (count: Int, bytes: Int64)) -> String {
        guard selection.count > 0 else {
            return String(localized: "No Items Selected", comment: "Manager footer, nothing selected.")
        }
        let count = String.localizedStringWithFormat(
            String(localized: "%lld Items Selected", comment: "Manager footer selected count."),
            selection.count
        )
        return "\(count)  ·  \(ManagerByteText.string(selection.bytes))"
    }

    /// Count and bytes selected within the category currently shown — an O(1)
    /// read of the view-model's incrementally-maintained per-category totals,
    /// rather than a per-render pass over the category's file list.
    private func categorySelection() -> (count: Int, bytes: Int64) {
        (viewModel.selectedCount(in: category), viewModel.selectedBytes(in: category))
    }

    /// The reviewable files of the active category (selectable copies for the
    /// image categories; all files for the others).
    private var currentCategoryFiles: [ScannedFile] {
        switch category {
        case .largeOld: return largeOldCache.allSorted
        case .duplicates: return viewModel.duplicateCopies
        case .similar: return viewModel.similarCopies
        case .downloads: return viewModel.downloads.map(\.file)
        }
    }

    /// The active category's file URLs, the delete scope for the footer's Remove.
    private var currentCategoryURLs: Set<URL> {
        Set(currentCategoryFiles.map(\.url))
    }

    // MARK: - Shared pieces

    private func paneHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
    }

    private func checkbox(for url: URL) -> some View {
        ManagerRowCheckbox(isOn: viewModel.isSelected(url)) {
            viewModel.toggleSelection(url: url)
        }
    }

    private func breadcrumb(_ url: URL) -> some View {
        Text(breadcrumbText(url))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
    }

    private func browserIcon(for group: MyClutterDownloadGroup) -> some View {
        Group {
            if let image = AppIconLoader.image(bundleID: group.bundleID) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "arrow.down.circle.fill").resizable().foregroundStyle(Self.accent)
            }
        }
    }

    private func selectLabel(for copies: [ScannedFile]) -> String {
        let selected = copies.filter { viewModel.isSelected($0.url) }.count
        if selected == 0 { return String(localized: "None", comment: "Select trigger, none.") }
        if selected == copies.count { return String(localized: "All", comment: "Select trigger, all.") }
        return String(localized: "Some", comment: "Select trigger, some.")
    }

    // MARK: - Helpers

    private func resetMiddleSelection() {
        largeOldFacet = .all
        selectedGroupID = nil
        selectedBrowser = nil
        focusedURL = nil
    }

    /// Home path and name resolved once for the process — `breadcrumbText`
    /// runs per visible row, so it must not re-derive them on every call.
    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private static let homeName = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent

    private func breadcrumbText(_ url: URL) -> String {
        var path = url.deletingLastPathComponent().path
        if path.hasPrefix(Self.homePath) { path = String(path.dropFirst(Self.homePath.count)) }
        let components = path.split(separator: "/").map(String.init)
        return ([Self.homeName] + components).joined(separator: " › ")
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Precomputed Large & Old facet data: each facet's files (sorted largest
/// first) and total bytes. Built once off the main actor when the result set
/// changes so the manager never re-sorts or re-sums the full list on a render.
/// `Sendable` so it can be returned from a detached task.
private struct LargeOldFacetCache: Sendable {
    var allSorted: [ScannedFile] = []
    var byKind: [MyClutterFileKind: [ScannedFile]] = [:]
    var bySize: [MyClutterSizeBucket: [ScannedFile]] = [:]
    var bytesAll: Int64 = 0
    var bytesByKind: [MyClutterFileKind: Int64] = [:]
    var bytesBySize: [MyClutterSizeBucket: Int64] = [:]

    init() {}

    init(files: [ScannedFile]) {
        let sorted = files.sorted { $0.size > $1.size }
        allSorted = sorted
        // One pass over the already-sorted list keeps every per-facet bucket in
        // size order without a second sort.
        for file in sorted {
            bytesAll += file.size
            let kind = MyClutterFileKind.of(file.url)
            byKind[kind, default: []].append(file)
            bytesByKind[kind, default: 0] += file.size
            let bucket = MyClutterSizeBucket.of(file.size)
            bySize[bucket, default: []].append(file)
            bytesBySize[bucket, default: 0] += file.size
        }
    }
}
