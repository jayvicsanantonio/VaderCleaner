// AppUpdaterCoverageTests.swift
// Drives the App Updater's coverage reporting — how discovered apps are partitioned into checked, unreachable, self-updating, and unmonitored, so the pane can state what it inspected rather than only what it found.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdaterCoverageTests: XCTestCase {

    // MARK: - Coverage

    func test_init_coverageIsEmpty() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.coverage, UpdateCoverage())
        XCTAssertEqual(vm.coverage.total, 0)
    }

    /// Coverage partitions the discovered apps exactly — every app lands in
    /// one bucket and none is counted twice. Without this the headline
    /// "checked N of M" would be arithmetic the user can't trust.
    func test_checkForUpdates_coveragePartitionsEveryDiscoveredApp() async {
        let updatable = makeApp(name: "Helio", bundleID: "com.acme.helio",
                                version: "1.0.0", isAppStore: true)
        let current = makeApp(name: "Solar", bundleID: "com.acme.solar",
                              version: "2.0.0", isAppStore: true)
        let offline = makeApp(name: "Vapor", bundleID: "com.acme.vapor",
                              version: "1.0.0", isAppStore: true)
        let selfUpdater = makeApp(name: "Chromium", bundleID: "com.acme.chromium",
                                  version: "1.0.0", isAppStore: false)
        let bare = makeApp(name: "Bare", bundleID: "com.acme.bare",
                           version: "1.0.0", isAppStore: false)

        let vm = makeViewModel(
            discover: { _ in [updatable, current, offline, selfUpdater, bare] },
            checkAppStore: { bundleID in
                switch bundleID {
                case "com.acme.helio":
                    return .found(AppStoreLookup(
                        version: "2.0.0",
                        appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                    ))
                case "com.acme.solar":
                    return .found(AppStoreLookup(
                        version: "2.0.0",
                        appStoreURL: URL(string: "https://apps.apple.com/app/id2")!
                    ))
                default:
                    return .unreachable
                }
            },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { app in
                app.bundleID == "com.acme.chromium" ? .selfUpdating(.keystone) : .unmonitored
            }
        )

        await vm.checkForUpdates()

        XCTAssertEqual(vm.coverage.checked, 2)
        XCTAssertEqual(vm.coverage.unreachable, 1)
        XCTAssertEqual(vm.coverage.selfUpdating.map(\.app.bundleID), ["com.acme.chromium"])
        XCTAssertEqual(vm.coverage.selfUpdating.map(\.updater), [.keystone])
        XCTAssertEqual(vm.coverage.unmonitored.map(\.bundleID), ["com.acme.bare"])
        XCTAssertEqual(vm.coverage.total, 5)
    }

    /// The regression this whole change exists to prevent: a machine where
    /// nothing is checkable must report *that*, not an empty list that
    /// reads as "everything is current".
    func test_checkForUpdates_allSkippedReportsCoverageAndStaysReady() async {
        let apps = (0..<3).map { index in
            makeApp(name: "Plain\(index)", bundleID: "com.acme.plain\(index)",
                    version: "1.0.0", isAppStore: false)
        }
        let vm = makeViewModel(
            discover: { _ in apps },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { _ in .unmonitored }
        )

        await vm.checkForUpdates()

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.availableUpdates.isEmpty)
        XCTAssertEqual(vm.coverage.checked, 0)
        XCTAssertEqual(vm.coverage.unmonitored.count, 3)
        XCTAssertEqual(vm.coverage.total, 3)
    }

    /// Self-updating apps are reassurance, not a to-do list, so they must
    /// never be folded into the unmonitored count.
    func test_checkForUpdates_coverageSeparatesSelfUpdatingFromUnmonitored() async {
        let keystone = makeApp(name: "Chromium", bundleID: "com.acme.chromium",
                               version: "1.0.0", isAppStore: false)
        let squirrel = makeApp(name: "Electra", bundleID: "com.acme.electra",
                               version: "1.0.0", isAppStore: false)
        let vm = makeViewModel(
            discover: { _ in [keystone, squirrel] },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { app in
                app.bundleID == "com.acme.chromium"
                    ? .selfUpdating(.keystone)
                    : .selfUpdating(.squirrel)
            }
        )

        await vm.checkForUpdates()

        XCTAssertTrue(vm.coverage.unmonitored.isEmpty)
        XCTAssertEqual(
            vm.coverage.selfUpdating.map(\.updater).sorted { $0.rawValue < $1.rawValue },
            [.keystone, .squirrel]
        )
    }

    /// A second pass replaces coverage rather than adding to it — an app
    /// uninstalled between checks must drop out of the counts.
    func test_checkForUpdates_coverageIsReplacedNotAccumulated() async {
        let apps = ActorBox<[AppInfo]>([
            makeApp(name: "A", bundleID: "com.acme.a", version: "1.0", isAppStore: false),
            makeApp(name: "B", bundleID: "com.acme.b", version: "1.0", isAppStore: false),
        ])
        let vm = makeViewModel(
            discover: { _ in await apps.value },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { _ in .unmonitored }
        )

        await vm.checkForUpdates()
        XCTAssertEqual(vm.coverage.total, 2)

        await apps.set([makeApp(name: "A", bundleID: "com.acme.a",
                                version: "1.0", isAppStore: false)])
        await vm.checkForUpdates()

        XCTAssertEqual(vm.coverage.total, 1)
        XCTAssertEqual(vm.coverage.unmonitored.map(\.bundleID), ["com.acme.a"])
    }

    /// A failed discovery clears coverage alongside the update list — stale
    /// counts beside an error message would misreport what was inspected.
    func test_checkForUpdates_discoveryFailureClearsCoverage() async {
        let apps = [makeApp(name: "A", bundleID: "com.acme.a",
                            version: "1.0", isAppStore: false)]
        let shouldFail = ActorBox(false)
        let vm = makeViewModel(
            discover: { _ in
                if await shouldFail.value { throw AppUpdaterError.networkUnavailable }
                return apps
            },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { _ in .unmonitored }
        )

        await vm.checkForUpdates()
        XCTAssertEqual(vm.coverage.total, 1)

        await shouldFail.set(true)
        await vm.checkForUpdates()

        XCTAssertEqual(vm.coverage, UpdateCoverage())
    }

    // MARK: - Helpers

    private func makeViewModel(
        discover: @escaping AppUpdaterViewModel.Discover = { _ in [] },
        checkAppStore: @escaping AppUpdaterViewModel.CheckAppStore = { _ in .noResult },
        checkSparkle: @escaping AppUpdaterViewModel.CheckSparkle = { _ in .noResult },
        classifyUnchecked: @escaping UpdateProbe.ClassifyUnchecked = { _ in .unmonitored },
        opener: @escaping AppUpdaterViewModel.Opener = { _ in }
    ) -> AppUpdaterViewModel {
        AppUpdaterViewModel(
            discover: discover,
            checkAppStore: checkAppStore,
            checkSparkle: checkSparkle,
            classifyUnchecked: classifyUnchecked,
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
