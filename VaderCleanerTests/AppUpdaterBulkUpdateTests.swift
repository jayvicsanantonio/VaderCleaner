// AppUpdaterBulkUpdateTests.swift
// Drives the Updater's batch action — collapsing App Store entries to a single Updates page, deduplicating shared download URLs, and leaving the single-app action opening its own product page.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdaterBulkUpdateTests: XCTestCase {

    // MARK: - Bulk update routing

    /// Every App Store update collapses to a single open of the Mac App
    /// Store's Updates page. Opening one product page per app buries the
    /// user in windows and still makes them press Update N times.
    func test_updateAll_collapsesAppStoreUpdatesToOneUpdatesPage() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(
            updates: [
                update(bundleID: "com.acme.a", source: .appStore, url: "https://apps.apple.com/app/id1"),
                update(bundleID: "com.acme.b", source: .appStore, url: "https://apps.apple.com/app/id2"),
                update(bundleID: "com.acme.c", source: .appStore, url: "https://apps.apple.com/app/id3"),
            ],
            opened: opened
        )

        await vm.updateAll()

        let urls = await opened.value
        XCTAssertEqual(urls, [AppUpdaterViewModel.appStoreUpdatesURL])
    }

    /// A mixed batch opens the Updates page once and each distinct web
    /// download once.
    func test_updateAll_opensUpdatesPageOnceAlongsideEachWebDownload() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(
            updates: [
                update(bundleID: "com.acme.a", source: .appStore, url: "https://apps.apple.com/app/id1"),
                update(bundleID: "com.acme.b", source: .appStore, url: "https://apps.apple.com/app/id2"),
                update(bundleID: "com.acme.w", source: .sparkle, url: "https://example.com/w.dmg"),
            ],
            opened: opened
        )

        await vm.updateAll()

        let urls = await opened.value
        XCTAssertEqual(urls.filter { $0 == AppUpdaterViewModel.appStoreUpdatesURL }.count, 1)
        XCTAssertTrue(urls.contains(URL(string: "https://example.com/w.dmg")!))
        XCTAssertEqual(urls.count, 2)
    }

    /// Two apps sharing a download URL (a suite installer) must not
    /// trigger the same download twice.
    func test_updateAll_deduplicatesRepeatedDownloadURLs() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(
            updates: [
                update(bundleID: "com.acme.one", source: .sparkle, url: "https://example.com/suite.dmg"),
                update(bundleID: "com.acme.two", source: .sparkle, url: "https://example.com/suite.dmg"),
            ],
            opened: opened
        )

        await vm.updateAll()

        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://example.com/suite.dmg")!])
    }

    /// With no App Store entries the Updates page is not opened at all.
    func test_updateAll_webOnlyBatchDoesNotOpenUpdatesPage() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(
            updates: [update(bundleID: "com.acme.w", source: .sparkle, url: "https://example.com/w.dmg")],
            opened: opened
        )

        await vm.updateAll()

        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://example.com/w.dmg")!])
    }

    /// An empty batch opens nothing.
    func test_update_emptyBatchOpensNothing() async {
        let opened = ActorBox<[URL]>([])
        let vm = makeViewModel(opener: { url in await opened.set(opened.value + [url]) })
        await vm.update([])
        let urls = await opened.value
        XCTAssertTrue(urls.isEmpty)
    }

    /// Updating a single App Store app still opens its product page —
    /// that action means "show me this app", not "go update everything".
    func test_update_singleAppStoreEntryOpensItsProductPage() async {
        let opened = ActorBox<[URL]>([])
        let vm = makeViewModel(opener: { url in await opened.set(opened.value + [url]) })
        await vm.update(update(bundleID: "com.acme.a", source: .appStore,
                               url: "https://apps.apple.com/app/id1"))
        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://apps.apple.com/app/id1")!])
    }

    /// A view model already in `.ready` carrying `updates`, so bulk
    /// routing can be driven without restating a whole check.
    private func readyViewModel(
        updates: [UpdateInfo],
        opened: ActorBox<[URL]>
    ) async -> AppUpdaterViewModel {
        let apps = updates.map { info in
            makeApp(name: info.appName, bundleID: info.bundleID,
                    version: info.installedVersion, isAppStore: info.source == .appStore)
        }
        let byBundleID = Dictionary(uniqueKeysWithValues: updates.map { ($0.bundleID, $0) })
        let vm = makeViewModel(
            discover: { _ in apps },
            checkAppStore: { bundleID in
                guard let info = byBundleID[bundleID] else { return .noResult }
                return .found(AppStoreLookup(version: info.latestVersion, appStoreURL: info.updateURL))
            },
            checkSparkle: { app in
                guard let info = byBundleID[app.bundleID] else { return .noResult }
                return .found(SparkleAppcastItem(
                    shortVersion: info.latestVersion,
                    version: nil,
                    downloadURL: info.updateURL
                ))
            },
            opener: { url in await opened.set(opened.value + [url]) }
        )
        await vm.checkForUpdates()
        return vm
    }

    private func update(
        bundleID: String,
        source: UpdateSource,
        url: String
    ) -> UpdateInfo {
        UpdateInfo(
            appName: bundleID,
            bundleID: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleID).app"),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: source,
            updateURL: URL(string: url)!
        )
    }

    private func makeViewModel(
        discover: @escaping AppUpdaterViewModel.Discover = { _ in [] },
        checkAppStore: @escaping AppUpdaterViewModel.CheckAppStore = { _ in .noResult },
        checkSparkle: @escaping AppUpdaterViewModel.CheckSparkle = { _ in .noResult },
        opener: @escaping AppUpdaterViewModel.Opener = { _ in }
    ) -> AppUpdaterViewModel {
        AppUpdaterViewModel(
            discover: discover,
            checkAppStore: checkAppStore,
            checkSparkle: checkSparkle,
            classifyUnchecked: { _ in .unmonitored },
            opener: opener
        )
    }

    private func makeApp(
        name: String,
        bundleID: String,
        version: String,
        isAppStore: Bool
    ) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: version,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: isAppStore
        )
    }
}

private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}
