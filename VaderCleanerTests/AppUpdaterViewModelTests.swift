// AppUpdaterViewModelTests.swift
// Drives the AppUpdaterViewModel state machine — check-for-updates dispatch, App Store + Sparkle result merging, version-equal suppression, opener routing, and failure paths — using injected fakes so no real apps or network are touched.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdaterViewModelTests: XCTestCase {

    // MARK: - Initial state

    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    // MARK: - Discovery

    /// `checkForUpdates()` lands `.ready` with a merged list of App Store +
    /// Sparkle results, suppressing any app whose installed version already
    /// matches the latest.
    func test_checkForUpdates_mergesAppStoreAndSparkleResults() async {
        let masApp = makeApp(
            name: "Helio",
            bundleID: "com.acme.helio",
            version: "5.0.0",
            isAppStore: true
        )
        let sparkleApp = makeApp(
            name: "Mango",
            bundleID: "com.acme.mango",
            version: "1.0.0",
            isAppStore: false
        )
        let upToDateApp = makeApp(
            name: "Solar",
            bundleID: "com.unrelated.solar",
            version: "2.0.0",
            isAppStore: true
        )

        let vm = makeViewModel(
            discover: { _ in [masApp, sparkleApp, upToDateApp] },
            checkAppStore: { bundleID in
                switch bundleID {
                case "com.acme.helio":
                    return AppStoreLookup(
                        version: "5.4.1",
                        appStoreURL: URL(string: "https://apps.apple.com/app/id123")!
                    )
                case "com.unrelated.solar":
                    return AppStoreLookup(
                        version: "2.0.0",
                        appStoreURL: URL(string: "https://apps.apple.com/app/id999")!
                    )
                default:
                    return nil
                }
            },
            checkSparkle: { app in
                guard app.bundleID == "com.acme.mango" else { return nil }
                return SparkleAppcastItem(
                    shortVersion: "2.0.0",
                    version: "2000",
                    downloadURL: URL(string: "https://example.com/mango-2.dmg")!
                )
            }
        )

        await vm.checkForUpdates()

        XCTAssertEqual(vm.phase, .ready)
        let bundleIDs = vm.availableUpdates.map(\.bundleID).sorted()
        XCTAssertEqual(bundleIDs, ["com.acme.helio", "com.acme.mango"])

        let helio = vm.availableUpdates.first(where: { $0.bundleID == "com.acme.helio" })
        XCTAssertEqual(helio?.source, .appStore)
        XCTAssertEqual(helio?.latestVersion, "5.4.1")

        let mango = vm.availableUpdates.first(where: { $0.bundleID == "com.acme.mango" })
        XCTAssertEqual(mango?.source, .sparkle)
        XCTAssertEqual(mango?.latestVersion, "2.0.0")
    }

    /// Apps whose installed version already matches the latest must NOT
    /// appear in `availableUpdates`. Without this filter, the UI would show
    /// "Update" rows for up-to-date apps and the user would be misled.
    func test_checkForUpdates_suppressesUpToDateApps() async {
        let app = makeApp(
            name: "Helio",
            bundleID: "com.acme.helio",
            version: "1.0.0",
            isAppStore: true
        )
        let vm = makeViewModel(
            discover: { _ in [app] },
            checkAppStore: { _ in
                AppStoreLookup(
                    version: "1.0.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                )
            }
        )
        await vm.checkForUpdates()
        XCTAssertTrue(vm.availableUpdates.isEmpty)
        XCTAssertEqual(vm.phase, .ready)
    }

    /// An empty installed-apps list short-circuits to `.ready` with no
    /// updates — no checker calls.
    func test_checkForUpdates_noAppsLandsReady() async {
        let appStoreCalls = ActorBox(0)
        let sparkleCalls = ActorBox(0)
        let vm = makeViewModel(
            discover: { _ in [] },
            checkAppStore: { _ in await appStoreCalls.increment(); return nil },
            checkSparkle: { _ in await sparkleCalls.increment(); return nil }
        )
        await vm.checkForUpdates()
        XCTAssertEqual(vm.phase, .ready)
        let appStore = await appStoreCalls.value
        let sparkle = await sparkleCalls.value
        XCTAssertEqual(appStore, 0)
        XCTAssertEqual(sparkle, 0)
    }

    /// A throwing discovery surfaces `.failed` so the view can render its
    /// "Try again" state.
    func test_checkForUpdates_discoveryFailureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(
            discover: { _ in throw BoomError() }
        )
        await vm.checkForUpdates()
        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Update routing

    /// `update(_:)` opens the update URL via the injected opener. The
    /// production opener delegates to `NSWorkspace.open`.
    func test_update_invokesOpenerWithUpdateURL() async {
        let opened = ActorBox<[URL]>([])
        let vm = makeViewModel(
            opener: { url in await opened.set(opened.value + [url]) }
        )
        let info = UpdateInfo(
            appName: "Helio",
            bundleID: "com.acme.helio",
            bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .appStore,
            updateURL: URL(string: "https://apps.apple.com/app/id1")!
        )
        await vm.update(info)
        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://apps.apple.com/app/id1")!])
    }

    /// `updateAll()` opens every available update's URL.
    func test_updateAll_opensEveryURL() async {
        let opened = ActorBox<[URL]>([])
        let app = makeApp(
            name: "Helio",
            bundleID: "com.acme.helio",
            version: "1.0.0",
            isAppStore: true
        )
        let vm = makeViewModel(
            discover: { _ in [app] },
            checkAppStore: { _ in
                AppStoreLookup(
                    version: "2.0.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                )
            },
            opener: { url in await opened.set(opened.value + [url]) }
        )
        await vm.checkForUpdates()
        await vm.updateAll()
        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://apps.apple.com/app/id1")!])
    }

    // MARK: - Helpers

    private func makeViewModel(
        discover: @escaping AppUpdaterViewModel.Discover = { _ in [] },
        checkAppStore: @escaping AppUpdaterViewModel.CheckAppStore = { _ in nil },
        checkSparkle: @escaping AppUpdaterViewModel.CheckSparkle = { _ in nil },
        opener: @escaping AppUpdaterViewModel.Opener = { _ in }
    ) -> AppUpdaterViewModel {
        AppUpdaterViewModel(
            discover: discover,
            checkAppStore: checkAppStore,
            checkSparkle: checkSparkle,
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

private extension ActorBox where Value == Int {
    func increment() { value += 1 }
}
