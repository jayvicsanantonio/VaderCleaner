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

        guard case .update(let info)? = outcomes.first?.outcome else {
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
            guard case .noUpdate? = outcomes.first?.outcome else {
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
        guard case .update(let info)? = outcomes.first?.outcome else {
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
            switch (outcomes[0].outcome, expected) {
            case (.noUpdate, "noUpdate"), (.unreachable, "unreachable"), (.skipped(_), "skipped"):
                break
            default:
                XCTFail("Expected \(expected), got \(outcomes[0].outcome)")
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

        guard case .update(let info)? = outcomes.first?.outcome else {
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
            switch (outcomes[0].outcome, expected) {
            case (.noUpdate, "noUpdate"), (.unreachable, "unreachable"), (.skipped(_), "skipped"):
                break
            default:
                XCTFail("Expected \(expected), got \(outcomes[0].outcome)")
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

    // MARK: - Skip classification

    /// An app with no queryable feed and no embedded updater lands in
    /// `.unmonitored` — the bucket the coverage report treats as a real
    /// blind spot rather than as reassurance.
    func test_outcomes_skippedCarriesUnmonitoredWhenNoSelfUpdaterDetected() async {
        let app = makeApp(name: "Bare", bundleID: "com.acme.bare", isAppStore: false)
        let probe = UpdateProbe(
            checkAppStore: { _ in .skipped },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { _ in .unmonitored }
        )

        let outcomes = await probe.outcomes(for: [app])

        guard case .skipped(let reason)? = outcomes.first?.outcome else {
            return XCTFail("Expected .skipped, got \(outcomes)")
        }
        XCTAssertEqual(reason, .unmonitored)
    }

    /// An app that ships its own updater is skipped for a benign reason,
    /// and the reason rides along so the UI can say which mechanism keeps
    /// it current instead of listing it as neglected.
    func test_outcomes_skippedCarriesSelfUpdaterWhenDetected() async {
        for updater in SelfUpdater.allCases {
            let app = makeApp(name: "Selfie", bundleID: "com.acme.selfie", isAppStore: false)
            let probe = UpdateProbe(
                checkAppStore: { _ in .skipped },
                checkSparkle: { _ in .skipped },
                classifyUnchecked: { _ in .selfUpdating(updater) }
            )

            let outcomes = await probe.outcomes(for: [app])

            guard case .skipped(let reason)? = outcomes.first?.outcome else {
                return XCTFail("Expected .skipped for \(updater), got \(outcomes)")
            }
            XCTAssertEqual(reason, .selfUpdating(updater))
        }
    }

    /// The classifier runs only for apps that were actually skipped —
    /// reading a bundle off disk for every checked app would be wasted work.
    func test_outcomes_doesNotClassifyAppsThatWereChecked() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio", isAppStore: true)
        let classified = ActorBox<[String]>([])
        let probe = UpdateProbe(
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { app in
                Task { await classified.append(app.bundleID) }
                return .unmonitored
            }
        )

        _ = await probe.outcomes(for: [app])

        let calls = await classified.value
        XCTAssertTrue(calls.isEmpty, "Checked apps must not be classified, got \(calls)")
    }

    // MARK: - Homebrew ownership

    /// A cask-installed app is never dispatched to a channel at all. This
    /// is the clobber guard: offering its Sparkle download would overwrite
    /// a Caskroom-tracked install and desync Homebrew's manifest, so the
    /// probe must not even produce an update row for it.
    func test_outcomes_caskOwnedAppIsSkippedWithoutContactingAnyChannel() async {
        let app = makeApp(name: "VLC", bundleID: "org.videolan.vlc", isAppStore: false)
        let checkerCalls = ActorBox(0)
        let probe = UpdateProbe(
            checkAppStore: { _ in await checkerCalls.increment(); return .noResult },
            checkSparkle: { _ in await checkerCalls.increment(); return .noResult },
            resolveHomebrewToken: { _ in "vlc" }
        )

        let outcomes = await probe.outcomes(for: [app])

        guard case .skipped(let reason)? = outcomes.first?.outcome else {
            return XCTFail("Expected .skipped, got \(outcomes)")
        }
        XCTAssertEqual(reason, .homebrew(token: "vlc"))
        let calls = await checkerCalls.value
        XCTAssertEqual(calls, 0, "A cask-owned app must not be checked at all")
    }

    /// Ownership is resolved per app, so an unmanaged app alongside a
    /// cask-owned one is still checked normally.
    func test_outcomes_unmanagedAppIsStillCheckedAlongsideCaskOwnedApp() async {
        let managed = makeApp(name: "VLC", bundleID: "org.videolan.vlc", isAppStore: false)
        let unmanaged = makeApp(name: "Telegram", bundleID: "ru.keepcoder.telegram",
                                version: "1.0", isAppStore: false)
        let probe = UpdateProbe(
            checkAppStore: { _ in .skipped },
            checkSparkle: { _ in
                .found(SparkleAppcastItem(
                    shortVersion: "2.0",
                    version: "2000",
                    downloadURL: URL(string: "https://example.com/t.dmg")!
                ))
            },
            resolveHomebrewToken: { $0.bundleID == "org.videolan.vlc" ? "vlc" : nil }
        )

        let outcomes = await probe.outcomes(for: [managed, unmanaged])

        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.app.bundleID, $0.outcome) })
        guard case .skipped(.homebrew(let token))? = byID["org.videolan.vlc"] else {
            return XCTFail("Expected VLC to be brew-managed")
        }
        XCTAssertEqual(token, "vlc")
        guard case .update(let info)? = byID["ru.keepcoder.telegram"] else {
            return XCTFail("Expected Telegram to yield an update")
        }
        XCTAssertEqual(info.latestVersion, "2.0")
    }

    /// With no Homebrew on the machine nothing is claimed, and every app
    /// is checked exactly as before.
    func test_outcomes_noHomebrewOwnershipLeavesEveryAppChecked() async {
        let app = makeApp(name: "Telegram", bundleID: "ru.keepcoder.telegram",
                          version: "1.0", isAppStore: true)
        let probe = UpdateProbe(
            checkAppStore: { _ in
                .found(AppStoreLookup(
                    version: "2.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/id1")!
                ))
            },
            checkSparkle: { _ in .skipped },
            resolveHomebrewToken: { _ in nil }
        )

        let outcomes = await probe.outcomes(for: [app])

        guard case .update? = outcomes.first?.outcome else {
            return XCTFail("Expected .update, got \(outcomes)")
        }
    }

    // MARK: - App association

    /// Results are produced in completion order, so each one must carry the
    /// app that produced it. Without the pairing the coverage lists cannot
    /// name which apps went unchecked.
    func test_outcomes_pairsEachResultWithTheAppThatProducedIt() async {
        let apps = (0..<20).map { index in
            makeApp(name: "App\(index)", bundleID: "com.acme.app\(index)",
                    version: "1.0", isAppStore: true)
        }
        let probe = UpdateProbe(
            checkAppStore: { bundleID in
                // Stagger completions so results genuinely arrive out of
                // dispatch order rather than trivially in sequence.
                try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...8_000_000))
                return .found(AppStoreLookup(
                    version: "2.0",
                    appStoreURL: URL(string: "https://apps.apple.com/app/\(bundleID)")!
                ))
            },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { _ in .unmonitored }
        )

        let outcomes = await probe.outcomes(for: apps)

        XCTAssertEqual(outcomes.count, 20)
        for result in outcomes {
            guard case .update(let info) = result.outcome else {
                return XCTFail("Expected .update for \(result.app.bundleID)")
            }
            XCTAssertEqual(info.bundleID, result.app.bundleID)
            XCTAssertEqual(info.bundleURL, result.app.bundleURL)
        }
        XCTAssertEqual(Set(outcomes.map(\.app.bundleID)).count, 20)
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
