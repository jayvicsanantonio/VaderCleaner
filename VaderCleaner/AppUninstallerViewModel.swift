// AppUninstallerViewModel.swift
// State machine and selection logic behind the App Uninstaller feature view — drives idle/loading/ready/uninstalling/complete transitions and routes the uninstall through an injected recycler.

import AppKit
import Foundation
import os.log

/// Drives the App Uninstaller feature view (load apps → select → uninstall → done).
///
/// Like `PrivacyViewModel` and `SystemJunkViewModel`, all collaborators are
/// injected as closures so unit tests can drive every transition without
/// touching real disk state. Production wiring lives in
/// `AppUninstallerViewModel.live()` below.
@MainActor
@Observable
final class AppUninstallerViewModel {

    /// Which step of the flow generated a `.failed` phase, so the view can
    /// pick the right heading.
    enum FailureStage: Equatable {
        case loading
        case uninstalling
    }

    /// Discrete phases the view binds to.
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case uninstalling
        case complete(bytesFreed: Int64)
        case failed(stage: FailureStage, message: String)
    }

    typealias Discover     = @Sendable (_ includingSystemApps: Bool) async throws -> [AppInfo]
    typealias FindFiles    = @Sendable (_ bundleID: String) async -> [AssociatedFile]
    typealias MeasureSize  = @Sendable (_ bundleURL: URL) async -> Int64
    /// Recycler contract: takes the `.app` bundle URL and the associated
    /// file URLs separately so the production implementation can verify
    /// the bundle itself was moved (and not just the user-writable
    /// residue). Returns the byte-count actually freed.
    typealias Recycle      = @Sendable (_ bundleURL: URL, _ associatedURLs: [URL]) async throws -> Int64

    private(set) var phase: Phase = .idle
    private(set) var apps: [AppInfo] = []
    private(set) var selectedAppID: AppInfo.ID?
    private(set) var associatedFiles: [AssociatedFile] = []
    private(set) var isLoadingAssociatedFiles: Bool = false
    /// Bundle size of the currently selected app, computed lazily on
    /// selection. `nil` until the per-app size measurement returns.
    private(set) var selectedAppBundleSize: Int64?
    var includesSystemApps: Bool = false
    var searchQuery: String = ""

    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let findFiles: FindFiles
    @ObservationIgnored private let measureSize: MeasureSize
    @ObservationIgnored private let recycle: Recycle
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "AppUninstallerViewModel")

    /// Cached associated-files results keyed by bundle URL path. Selecting
    /// the same app twice in a session doesn't re-walk the filesystem.
    @ObservationIgnored private var associatedFilesCache: [AppInfo.ID: [AssociatedFile]] = [:]

    /// Cached bundle sizes keyed by bundle URL path. The size walk is
    /// expensive on apps with many bundled frameworks, so we avoid
    /// repeating it after the first selection.
    @ObservationIgnored private var bundleSizeCache: [AppInfo.ID: Int64] = [:]

    /// Monotonically increasing token for in-flight operations — see the
    /// same pattern in `PrivacyViewModel` for the rationale.
    @ObservationIgnored private var loadGeneration: Int = 0
    @ObservationIgnored private var selectGeneration: Int = 0

    init(
        discover: @escaping Discover,
        findFiles: @escaping FindFiles,
        measureSize: @escaping MeasureSize = { _ in 0 },
        recycle: @escaping Recycle
    ) {
        self.discover = discover
        self.findFiles = findFiles
        self.measureSize = measureSize
        self.recycle = recycle
    }

    // MARK: - Public surface

    /// Convenience for the view layer — the currently selected `AppInfo`.
    var selectedApp: AppInfo? {
        guard let id = selectedAppID else { return nil }
        return apps.first(where: { $0.id == id })
    }

    /// Apps filtered by the current search query. Case-insensitive,
    /// substring match on name OR bundle ID. An empty query returns
    /// the full list.
    var filteredApps: [AppInfo] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(trimmed)
                || app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Sum of bundle size + all associated file sizes for the selected app.
    /// Returns 0 when nothing is selected — the footer renders "0 bytes" in
    /// that case, which is correct (nothing will be Trashed). The bundle
    /// size component is `nil` until the per-app size measurement
    /// returns; the footer reflects the partial total in the meantime.
    var totalReclaimableSize: Int64 {
        guard selectedApp != nil else { return 0 }
        let associated = associatedFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return (selectedAppBundleSize ?? 0) + associated
    }

    /// Associated files for the selected app grouped by category, in the
    /// stable declaration order of `AssociatedFileCategory.allCases`. The
    /// view renders one section per category.
    var associatedFilesByCategory: [(AssociatedFileCategory, [AssociatedFile])] {
        var bucketed: [AssociatedFileCategory: [AssociatedFile]] = [:]
        for file in associatedFiles {
            bucketed[file.category, default: []].append(file)
        }
        return AssociatedFileCategory.allCases.compactMap { category in
            guard let entries = bucketed[category], !entries.isEmpty else { return nil }
            return (category, entries)
        }
    }

    // MARK: - Actions

    /// Initial load — populates `apps` and lands in `.ready` (or `.failed`).
    func loadApps() async {
        let generation = beginLoad()
        phase = .loading
        let includes = includesSystemApps
        do {
            let result = try await discover(includes)
            guard self.loadGeneration == generation else { return }
            self.apps = result
            // Restore selection if the previously-selected app still exists,
            // otherwise drop it so the right-hand panel collapses to its
            // empty state.
            if let id = self.selectedAppID,
               result.contains(where: { $0.id == id }) {
                // keep current selection
            } else {
                self.selectedAppID = nil
                self.associatedFiles = []
            }
            self.phase = .ready
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("App discovery failed: \(String(describing: error), privacy: .private)")
            guard self.loadGeneration == generation else { return }
            self.apps = []
            self.selectedAppID = nil
            self.associatedFiles = []
            self.phase = .failed(stage: .loading, message: error.localizedDescription)
        }
    }

    /// Reloads the app list with the current `includesSystemApps` setting.
    /// Called by the view when the user flips the toggle so the visible
    /// list reflects the new filter immediately.
    func reloadApps() async {
        await loadApps()
    }

    /// Select an app by ID. Drives an async associated-files lookup AND
    /// a deferred bundle-size measurement in parallel, publishing
    /// `associatedFiles` and `selectedAppBundleSize` independently as
    /// each one finishes. A second `select(...)` before the first
    /// finishes cancels the older lookups so the right-hand panel can't
    /// flash stale rows from a previous selection.
    func select(_ appID: AppInfo.ID?) {
        selectedAppID = appID
        guard let appID, let app = apps.first(where: { $0.id == appID }) else {
            associatedFiles = []
            selectedAppBundleSize = nil
            isLoadingAssociatedFiles = false
            return
        }

        // Hydrate cached results synchronously so the UI doesn't flash
        // back to "loading" for an app the user has already inspected.
        selectedAppBundleSize = bundleSizeCache[appID]

        if let cachedFiles = associatedFilesCache[appID] {
            associatedFiles = cachedFiles
            isLoadingAssociatedFiles = false
            // Bundle-size measurement may still be outstanding even when
            // associated files were cached (e.g. an error path skipped it
            // last time); fall through to schedule it if needed.
        } else {
            associatedFiles = []
            isLoadingAssociatedFiles = true
        }

        let generation = beginSelect()
        let bundleID = app.bundleID
        let bundleURL = app.bundleURL
        let findFiles = findFiles
        let measureSize = measureSize
        let needsFiles = associatedFilesCache[appID] == nil
        let needsSize = bundleSizeCache[appID] == nil

        if needsFiles {
            Task { [weak self] in
                let found = await findFiles(bundleID)
                await MainActor.run { [weak self] in
                    guard let self, self.selectGeneration == generation else { return }
                    self.associatedFilesCache[appID] = found
                    if self.selectedAppID == appID {
                        self.associatedFiles = found
                        self.isLoadingAssociatedFiles = false
                    }
                }
            }
        }

        if needsSize {
            Task { [weak self] in
                let size = await measureSize(bundleURL)
                await MainActor.run { [weak self] in
                    guard let self, self.selectGeneration == generation else { return }
                    self.bundleSizeCache[appID] = size
                    if self.selectedAppID == appID {
                        self.selectedAppBundleSize = size
                    }
                }
            }
        }
    }

    /// Bundle size for an app, if it has been measured. Used by the list
    /// row to show "— MB" only after the size lands rather than during
    /// the initial discovery pass.
    func bundleSize(for appID: AppInfo.ID) -> Int64? {
        bundleSizeCache[appID]
    }

    /// Whether the destructive uninstall button should be enabled for
    /// the currently selected app. False while the associated-files
    /// scan is in flight — confirming early would only Trash the bundle
    /// and leave residual user data behind.
    var canUninstallSelectedApp: Bool {
        selectedApp != nil && !isLoadingAssociatedFiles
    }

    /// Uninstall the currently-selected app. Routes the bundle URL plus
    /// every associated file URL through the injected recycler. A no-op
    /// when nothing is selected or when the associated-files scan is
    /// still in flight — confirming early would Trash only the bundle
    /// and leave residual user data behind.
    func uninstall() async {
        guard let app = selectedApp, !isLoadingAssociatedFiles else { return }
        let associatedURLs = associatedFiles.map { $0.url }
        phase = .uninstalling
        do {
            let bytesFreed = try await recycle(app.bundleURL, associatedURLs)
            // Drop the app from the cached list and reset selection so the
            // user sees the result without a stale row pointing at a now-
            // Trashed bundle. `bytesFreed` is the recycler's authoritative
            // sum of what it actually moved to Trash — we do NOT fall back
            // to a planned/optimistic total, since that would claim
            // "X MB freed" when the recycler reports 0.
            apps.removeAll(where: { $0.id == app.id })
            selectedAppID = nil
            associatedFiles = []
            selectedAppBundleSize = nil
            associatedFilesCache.removeValue(forKey: app.id)
            bundleSizeCache.removeValue(forKey: app.id)
            phase = .complete(bytesFreed: bytesFreed)
        } catch {
            // Privacy: errors may include user-specific paths.
            log.error("App uninstall failed: \(String(describing: error), privacy: .private)")
            phase = .failed(stage: .uninstalling, message: error.localizedDescription)
        }
    }

    /// Returns the VM to `.ready` after a complete / failed phase so the
    /// user can pick another app to uninstall without restarting the
    /// discovery scan.
    func dismissResult() {
        phase = .ready
    }

    // MARK: - Generations

    private func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    private func beginSelect() -> Int {
        selectGeneration += 1
        return selectGeneration
    }
}

// MARK: - Production wiring

extension AppUninstallerViewModel {

    /// Build a view-model wired to the real `DefaultAppDiscovery`,
    /// `DefaultAssociatedFileFinder`, and `NSWorkspace.recycle(...)`.
    /// The exclusions snapshot is captured per lookup (a fresh
    /// `DefaultAssociatedFileFinder` is cheap — it only stores config)
    /// so a freshly-added Preferences exclusion takes effect on the next
    /// app selection.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> AppUninstallerViewModel {
        let discovery = DefaultAppDiscovery()
        return AppUninstallerViewModel(
            discover: { includingSystemApps in
                try await discovery.installedApps(includingSystemApps: includingSystemApps)
            },
            findFiles: { [weak exclusions] bundleID in
                let excluded = await MainActor.run {
                    (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                }
                let finder = DefaultAssociatedFileFinder(excluding: excluded)
                return await finder.find(forBundleID: bundleID)
            },
            measureSize: { url in
                await discovery.bundleSize(at: url)
            },
            recycle: { bundleURL, associatedURLs in
                try await Self.recycleViaWorkspace(
                    bundleURL: bundleURL,
                    associatedURLs: associatedURLs
                )
            }
        )
    }

    /// Bridges `NSWorkspace.recycle(_:completionHandler:)` (callback-based,
    /// returns a `[URL: URL]` map of original → Trash URLs) to an async
    /// throwing call that reports total bytes successfully Trashed.
    ///
    /// `NSWorkspace.recycle` does NOT throw on partial failure — it returns
    /// the items it managed to Trash and reports an error only when the
    /// entire batch failed. The `.app` bundle is the must-succeed item:
    /// if user-writable residue gets Trashed but the root-owned bundle
    /// itself is denied, the app is still installed and showing
    /// "Complete" would mislead the user (and leave a stale row in the
    /// list). We therefore throw whenever the bundle URL is missing from
    /// `newURLs`, even if some associated files succeeded. Associated-
    /// file partial failures are tolerated — they're best-effort
    /// cleanup, and "we Trashed the app and most of its data" is a
    /// useful outcome.
    private static func recycleViaWorkspace(
        bundleURL: URL,
        associatedURLs: [URL]
    ) async throws -> Int64 {
        let allURLs = [bundleURL] + associatedURLs
        // Capture sizes before recycle — once the path is in Trash, the
        // original URL doesn't stat anymore. We need this to credit
        // bytes-freed for the items the workspace successfully moved.
        let sizesByPath = sizes(for: allURLs)
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle(allURLs) { newURLs, error in
                let bundleMoved = newURLs.keys.contains(where: { $0.path == bundleURL.path })
                if !bundleMoved {
                    let resolvedError = error ?? NSError(
                        domain: "com.personal.VaderCleaner.AppUninstaller",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "The application bundle could not be moved to the Trash."
                        ]
                    )
                    continuation.resume(throwing: resolvedError)
                    return
                }
                var bytesFreed: Int64 = 0
                for original in newURLs.keys {
                    bytesFreed += sizesByPath[original.path] ?? 0
                }
                continuation.resume(returning: bytesFreed)
            }
        }
    }

    /// Pre-recycle size snapshot keyed by absolute path. Directories sum
    /// their regular-file children; missing items contribute 0.
    private static func sizes(for urls: [URL]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result[url.path] = 0
                continue
            }
            if !isDirectory.boolValue {
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber {
                    result[url.path] = size.int64Value
                } else {
                    result[url.path] = 0
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                result[url.path] = 0
                continue
            }
            var total: Int64 = 0
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true, let fileSize = values?.fileSize {
                    total += Int64(fileSize)
                }
            }
            result[url.path] = total
        }
        return result
    }
}
