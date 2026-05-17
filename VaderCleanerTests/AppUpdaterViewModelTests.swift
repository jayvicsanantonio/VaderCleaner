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
                    return .found(AppStoreLookup(
                        version: "5.4.1",
                        appStoreURL: URL(string: "https://apps.apple.com/app/id123")!
                    ))
                case "com.unrelated.solar":
                    return .found(AppStoreLookup(
                        version: "2.0.0",
                        appStoreURL: URL(string: "https://apps.apple.com/app/id999")!
                    ))
                default:
                    return .noResult
                }
            },
            checkSparkle: { app in
                guard app.bundleID == "com.acme.mango" else { return .noResult }
                return .found(SparkleAppcastItem(
                    shortVersion: "2.0.0",
                    version: "2000",
                    downloadURL: URL(string: "https://example.com/mango-2.dmg")!
                ))
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
                .found(AppStoreLookup(
                    version: "1.0.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                ))
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
            checkAppStore: { _ in await appStoreCalls.increment(); return .noResult },
            checkSparkle: { _ in await sparkleCalls.increment(); return .noResult }
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

    /// An offline check surfaces the actionable network copy, not
    /// Foundation's terser URLError description.
    func test_checkForUpdates_networkFailureSurfacesNetworkCopy() async {
        let vm = makeViewModel(
            discover: { _ in throw URLError(.notConnectedToInternet) }
        )
        await vm.checkForUpdates()
        XCTAssertEqual(
            vm.phase,
            .failed(message: "Could not check for updates. Check your internet connection.")
        )
    }

    /// Genuine offline: every feed we contacted was unreachable and not
    /// one came back with an answer. The whole check must surface the
    /// actionable network copy instead of the misleading "all apps are
    /// up to date" empty-but-`.ready` state.
    func test_checkForUpdates_allFeedsUnreachable_failsWithNetworkCopy() async {
        let masApp = makeApp(
            name: "Helio",
            bundleID: "com.acme.helio",
            version: "1.0.0",
            isAppStore: true
        )
        let sparkleApp = makeApp(
            name: "Mango",
            bundleID: "com.acme.mango",
            version: "1.0.0",
            isAppStore: false
        )
        let vm = makeViewModel(
            discover: { _ in [masApp, sparkleApp] },
            checkAppStore: { _ in .unreachable },
            checkSparkle: { _ in .unreachable }
        )
        await vm.checkForUpdates()
        XCTAssertEqual(
            vm.phase,
            .failed(message: "Could not check for updates. Check your internet connection.")
        )
        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    /// Partial degradation (Prompt 20) must survive: one unreachable
    /// feed alongside reachable ones still lands `.ready` showing the
    /// updates we could find — the dead feed is silently dropped, never
    /// promoted to a whole-check network error.
    func test_checkForUpdates_oneFeedUnreachableOthersReachable_staysReadyWithReachableUpdate() async {
        let downApp = makeApp(
            name: "Aria",
            bundleID: "com.acme.aria",
            version: "1.0.0",
            isAppStore: true
        )
        let liveApp = makeApp(
            name: "Bolt",
            bundleID: "com.acme.bolt",
            version: "1.0.0",
            isAppStore: true
        )
        let vm = makeViewModel(
            discover: { _ in [downApp, liveApp] },
            checkAppStore: { bundleID in
                guard bundleID == "com.acme.bolt" else { return .unreachable }
                return .found(AppStoreLookup(
                    version: "2.0.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id2")!
                ))
            }
        )
        await vm.checkForUpdates()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.availableUpdates.map(\.bundleID), ["com.acme.bolt"])
        XCTAssertEqual(vm.availableUpdates.first?.latestVersion, "2.0.0")
    }

    /// A non-network per-app failure (e.g. a decode error the live
    /// closure swallows as `.noResult`) is a *reached* feed — the server
    /// answered — so an all-`.noResult` pass with no updates stays
    /// `.ready`, not the offline copy. Guards the network detection
    /// against over-triggering.
    func test_checkForUpdates_nonNetworkFailuresStayReady() async {
        let app = makeApp(
            name: "Helio",
            bundleID: "com.acme.helio",
            version: "1.0.0",
            isAppStore: true
        )
        let vm = makeViewModel(
            discover: { _ in [app] },
            checkAppStore: { _ in .noResult }
        )
        await vm.checkForUpdates()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    /// Online but unremarkable: one feed responded with "nothing newer"
    /// while another happened to be unreachable, and there are no
    /// updates to show. Because at least one feed answered, this is the
    /// genuine "all apps are up to date" state, not offline — the lone
    /// flaky feed must not flip the whole check to the network error.
    func test_checkForUpdates_someReachableNoUpdatesWithFlakyFeed_staysReady() async {
        let reachedApp = makeApp(
            name: "Aria",
            bundleID: "com.acme.aria",
            version: "1.0.0",
            isAppStore: true
        )
        let flakyApp = makeApp(
            name: "Bolt",
            bundleID: "com.acme.bolt",
            version: "1.0.0",
            isAppStore: true
        )
        let vm = makeViewModel(
            discover: { _ in [reachedApp, flakyApp] },
            checkAppStore: { bundleID in
                bundleID == "com.acme.aria" ? .noResult : .unreachable
            }
        )
        await vm.checkForUpdates()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.availableUpdates.isEmpty)
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
                .found(AppStoreLookup(
                    version: "2.0.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                ))
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
        checkAppStore: @escaping AppUpdaterViewModel.CheckAppStore = { _ in .noResult },
        checkSparkle: @escaping AppUpdaterViewModel.CheckSparkle = { _ in .noResult },
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
