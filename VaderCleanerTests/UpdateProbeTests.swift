// UpdateProbeTests.swift
// Exercises the shared UpdateProbe pipeline — per-app channel routing, version comparison, UpdateInfo construction, outcome mapping, sorted update extraction, and the bounded-concurrency fan-out — using injected checker closures so no network is touched.

import XCTest
@testable import VaderCleaner

final class UpdateProbeTests: XCTestCase {

    // MARK: - Channel routing

    /// App Store apps go to the App Store checker, Sparkle apps to the
    /// Sparkle checker — the dispatch is exclusive, never both.
    func test_outcomes_routesEachAppToExactlyOneChannel() async {
        let masApp = makeApp(name: "Helio", bundleID: "com.acme.helio", isAppStore: true)
        let sparkleApp = makeApp(name: "Mango", bundleID: "com.acme.mango", isAppStore: false)

        let appStoreIDs = ActorBox<[String]>([])
        let sparkleIDs = ActorBox<[String]>([])
        let probe = UpdateProbe(
            checkAppStore: { bundleID in
                await appStoreIDs.append(bundleID)
                return .noResult
            },
            checkSparkle: { app in
                await sparkleIDs.append(app.bundleID)
                return .noResult
            }
        )

        _ = await probe.outcomes(for: [masApp, sparkleApp])

        let masCalls = await appStoreIDs.value
        let sparkleCalls = await sparkleIDs.value
        XCTAssertEqual(masCalls, ["com.acme.helio"])
        XCTAssertEqual(sparkleCalls, ["com.acme.mango"])
    }

    // MARK: - App Store outcomes

    /// A newer remote version folds into `.update` carrying a fully
    /// populated `UpdateInfo` for the App Store channel.
    func test_outcomes_appStoreNewerVersionYieldsUpdate() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio",
                          version: "1.0.0", isAppStore: true)
        let storeURL = URL(string: "https://apps.apple.com/app/id123")!
        let probe = UpdateProbe(
            checkAppStore: { _ in .found(AppStoreLookup(version: "2.0.0", appStoreURL: storeURL)) },
            checkSparkle: { _ in .skipped }
        )

        let outcomes = await probe.outcomes(for: [app])

        guard case .update(let info)? = outcomes.first else {
            return XCTFail("Expected .update, got \(outcomes)")
        }
        XCTAssertEqual(info.appName, "Helio")
        XCTAssertEqual(info.bundleID, "com.acme.helio")
        XCTAssertEqual(info.bundleURL, app.bundleURL)
        XCTAssertEqual(info.installedVersion, "1.0.0")
        XCTAssertEqual(info.latestVersion, "2.0.0")
        XCTAssertEqual(info.source, .appStore)
        XCTAssertEqual(info.updateURL, storeURL)
    }

    /// Remote version equal to (or older than) the installed one maps to
    /// `.noUpdate` so up-to-date apps never surface as update rows.
    func test_outcomes_appStoreEqualOrOlderVersionYieldsNoUpdate() async {
        for remote in ["1.0.0", "0.9.0"] {
            let app = makeApp(name: "Helio", bundleID: "com.acme.helio",
                              version: "1.0.0", isAppStore: true)
            let probe = UpdateProbe(
                checkAppStore: { _ in
                    .found(AppStoreLookup(
                        version: remote,
                        appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                    ))
                },
                checkSparkle: { _ in .skipped }
            )
            let outcomes = await probe.outcomes(for: [app])
            guard case .noUpdate? = outcomes.first else {
                return XCTFail("Expected .noUpdate for remote \(remote), got \(outcomes)")
            }
        }
    }

    /// A nil installed version is treated as "0" so any real remote
    /// version counts as newer.
    func test_outcomes_nilInstalledVersionTreatedAsZero() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio",
                          version: nil, isAppStore: true)
        let probe = UpdateProbe(
            checkAppStore: { _ in
                .found(AppStoreLookup(
                    version: "1.0.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                ))
            },
            checkSparkle: { _ in .skipped }
        )
        let outcomes = await probe.outcomes(for: [app])
        guard case .update(let info)? = outcomes.first else {
            return XCTFail("Expected .update, got \(outcomes)")
        }
        XCTAssertEqual(info.installedVersion, "0")
    }

    /// `CheckResult` cases that carry no usable payload pass through to the
    /// matching outcome for the App Store channel.
    func test_outcomes_appStoreNoResultUnreachableSkippedPassThrough() async {
        let cases: [(CheckResult<AppStoreLookup>, String)] = [
            (.noResult, "noUpdate"),
            (.unreachable, "unreachable"),
            (.skipped, "skipped"),
        ]
        for (result, expected) in cases {
            let app = makeApp(name: "Helio", bundleID: "com.acme.helio", isAppStore: true)
            let probe = UpdateProbe(
                checkAppStore: { _ in result },
                checkSparkle: { _ in .skipped }
            )
            let outcomes = await probe.outcomes(for: [app])
            XCTAssertEqual(outcomes.count, 1)
            switch (outcomes[0], expected) {
            case (.noUpdate, "noUpdate"), (.unreachable, "unreachable"), (.skipped, "skipped"):
                break
            default:
                XCTFail("Expected \(expected), got \(outcomes[0])")
            }
        }
    }

    // MARK: - Sparkle outcomes

    /// A newer appcast item folds into `.update` carrying a fully populated
    /// `UpdateInfo` for the Sparkle channel.
    func test_outcomes_sparkleNewerVersionYieldsUpdate() async {
        let app = makeApp(name: "Mango", bundleID: "com.acme.mango",
                          version: "1.0.0", isAppStore: false)
        let downloadURL = URL(string: "https://example.com/mango-2.dmg")!
        let probe = UpdateProbe(
            checkAppStore: { _ in .skipped },
            checkSparkle: { _ in
                .found(SparkleAppcastItem(
                    shortVersion: "2.0.0",
                    version: "2000",
                    downloadURL: downloadURL
                ))
            }
        )

        let outcomes = await probe.outcomes(for: [app])

        guard case .update(let info)? = outcomes.first else {
            return XCTFail("Expected .update, got \(outcomes)")
        }
        XCTAssertEqual(info.appName, "Mango")
        XCTAssertEqual(info.installedVersion, "1.0.0")
        XCTAssertEqual(info.latestVersion, "2.0.0")
        XCTAssertEqual(info.source, .sparkle)
        XCTAssertEqual(info.updateURL, downloadURL)
    }

    /// An up-to-date Sparkle app maps to `.noUpdate`, and the no-payload
    /// `CheckResult` cases pass through for the Sparkle channel too.
    func test_outcomes_sparkleNoResultUnreachableSkippedPassThrough() async {
        let cases: [(CheckResult<SparkleAppcastItem>, String)] = [
            (.noResult, "noUpdate"),
            (.unreachable, "unreachable"),
            (.skipped, "skipped"),
        ]
        for (result, expected) in cases {
            let app = makeApp(name: "Mango", bundleID: "com.acme.mango", isAppStore: false)
            let probe = UpdateProbe(
                checkAppStore: { _ in .skipped },
                checkSparkle: { _ in result }
            )
            let outcomes = await probe.outcomes(for: [app])
            XCTAssertEqual(outcomes.count, 1)
            switch (outcomes[0], expected) {
            case (.noUpdate, "noUpdate"), (.unreachable, "unreachable"), (.skipped, "skipped"):
                break
            default:
                XCTFail("Expected \(expected), got \(outcomes[0])")
            }
        }
    }

    // MARK: - availableUpdates

    /// `availableUpdates(for:)` keeps only the `.update` payloads, sorted
    /// case-insensitively by app name so list order is deterministic.
    func test_availableUpdates_extractsUpdatesSortedByNameCaseInsensitively() async {
        let apps = [
            makeApp(name: "zeta", bundleID: "com.acme.zeta", version: "1.0", isAppStore: true),
            makeApp(name: "Stale", bundleID: "com.acme.stale", version: "9.9", isAppStore: true),
            makeApp(name: "Alpha", bundleID: "com.acme.alpha", version: "1.0", isAppStore: true),
        ]
        let probe = UpdateProbe(
            checkAppStore: { bundleID in
                guard bundleID != "com.acme.stale" else { return .noResult }
                return .found(AppStoreLookup(
                    version: "2.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/\(bundleID)")!
                ))
            },
            checkSparkle: { _ in .skipped }
        )

        let updates = await probe.availableUpdates(for: apps)

        XCTAssertEqual(updates.map(\.appName), ["Alpha", "zeta"])
    }

    /// An empty app list yields no updates and never calls a checker.
    func test_availableUpdates_emptyAppsYieldsEmptyWithoutCheckerCalls() async {
        let calls = ActorBox(0)
        let probe = UpdateProbe(
            checkAppStore: { _ in await calls.increment(); return .noResult },
            checkSparkle: { _ in await calls.increment(); return .noResult }
        )
        let updates = await probe.availableUpdates(for: [])
        XCTAssertTrue(updates.isEmpty)
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    // MARK: - Bounded concurrency

    /// The fan-out never holds more than `maxConcurrentChecks` probes in
    /// flight, so a machine with hundreds of apps can't stampede the
    /// iTunes Search API or Sparkle hosts.
    func test_outcomes_neverExceedsMaxConcurrentChecks() async {
        let apps = (0..<20).map { index in
            makeApp(name: "App\(index)", bundleID: "com.acme.app\(index)", isAppStore: true)
        }
        let gauge = ConcurrencyGauge()
        let probe = UpdateProbe(
            checkAppStore: { _ in
                await gauge.enter()
                try? await Task.sleep(nanoseconds: 5_000_000)
                await gauge.exit()
                return .noResult
            },
            checkSparkle: { _ in .skipped }
        )

        let outcomes = await probe.outcomes(for: apps)

        XCTAssertEqual(outcomes.count, 20)
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, UpdateProbe.maxConcurrentChecks)
        XCTAssertGreaterThan(peak, 1, "Probes should actually run concurrently")
    }

    // MARK: - Fixtures

    private func makeApp(
        name: String,
        bundleID: String,
        version: String? = "1.0.0",
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

/// Tracks how many probe bodies are inside the checker simultaneously and
/// records the high-water mark.
private actor ConcurrencyGauge {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
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

private extension ActorBox where Value == [String] {
    func append(_ element: String) { value.append(element) }
}
