// AppUpdaterHomebrewMergeTests.swift
// Drives merging Homebrew's outdated casks into the Updater's single list — joining cask ownership to brew's version pairs, keeping brew rows unopenable, and partitioning a batch so each row reaches the mechanism that can actually install it.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdaterHomebrewMergeTests: XCTestCase {

    /// A cask-owned app with a brew update joins the main list rather than
    /// living in a separate facet the user has to go find.
    func test_setHomebrewOutdated_mergesCaskUpdatesIntoAvailableUpdates() async {
        let vm = makeViewModel(apps: [chromeApp], ownedTokens: ["Google Chrome.app": "google-chrome"])
        await vm.checkForUpdates()
        XCTAssertTrue(vm.availableUpdates.isEmpty)

        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0")])

        XCTAssertEqual(vm.availableUpdates.map(\.appName), ["Google Chrome"])
        let row = vm.availableUpdates[0]
        XCTAssertEqual(row.source, .homebrew)
        XCTAssertEqual(row.homebrewToken, "google-chrome")
        XCTAssertEqual(row.installedVersion, "150.0")
        XCTAssertEqual(row.latestVersion, "151.0")
    }

    /// A brew row carries no URL at all. That is structural, not a guard:
    /// there is nothing to open, so no code path can hand a cask-owned app
    /// a direct download and overwrite a Caskroom-tracked install.
    func test_setHomebrewOutdated_caskRowsHaveNoOpenableURL() async {
        let vm = makeViewModel(apps: [chromeApp], ownedTokens: ["Google Chrome.app": "google-chrome"])
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0")])

        XCTAssertNil(vm.availableUpdates[0].updateURL)
    }

    /// An outdated cask that owns no installed app contributes no row —
    /// CLI-only casks have no app to show.
    func test_setHomebrewOutdated_ignoresOutdatedCasksOwningNoApp() async {
        let vm = makeViewModel(apps: [chromeApp], ownedTokens: ["Google Chrome.app": "google-chrome"])
        await vm.checkForUpdates()

        vm.setHomebrewOutdated([outdated(token: "gcloud-cli", from: "1", to: "2")])

        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    /// A cask-owned app brew considers current contributes no row.
    func test_setHomebrewOutdated_ignoresUpToDateCasks() async {
        let vm = makeViewModel(apps: [chromeApp], ownedTokens: ["Google Chrome.app": "google-chrome"])
        await vm.checkForUpdates()

        vm.setHomebrewOutdated([])

        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    /// Pinned packages are deliberately held back and must never be swept
    /// into the list, matching `HomebrewViewModel.upgrade`.
    func test_setHomebrewOutdated_excludesPinnedCasks() async {
        let vm = makeViewModel(apps: [chromeApp], ownedTokens: ["Google Chrome.app": "google-chrome"])
        await vm.checkForUpdates()

        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0", pinned: true)])

        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    /// Direct and brew rows share one list, sorted together, so the user
    /// sees one inventory rather than two half-lists.
    func test_availableUpdates_sortsDirectAndBrewRowsTogether() async {
        let vm = makeViewModel(
            apps: [chromeApp, telegramApp],
            ownedTokens: ["Google Chrome.app": "google-chrome"],
            sparkleVersion: "12.9"
        )
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0")])

        XCTAssertEqual(vm.availableUpdates.map(\.appName), ["Google Chrome", "Telegram"])
    }

    /// A re-check must not drop the merged brew rows.
    func test_checkForUpdates_retainsMergedBrewRows() async {
        let vm = makeViewModel(apps: [chromeApp], ownedTokens: ["Google Chrome.app": "google-chrome"])
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0")])

        await vm.checkForUpdates()

        XCTAssertEqual(vm.availableUpdates.map(\.homebrewToken), ["google-chrome"])
    }

    // MARK: - Batch partitioning

    /// The batch action must route each row to the mechanism that can
    /// install it: brew rows are upgraded in place, everything else opens.
    func test_partition_separatesBrewTokensFromOpenableUpdates() async {
        let vm = makeViewModel(
            apps: [chromeApp, telegramApp],
            ownedTokens: ["Google Chrome.app": "google-chrome"],
            sparkleVersion: "12.9"
        )
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0")])

        let plan = vm.updatePlan(for: vm.availableUpdates)

        XCTAssertEqual(plan.homebrewTokens, ["google-chrome"])
        XCTAssertEqual(plan.openable.map(\.appName), ["Telegram"])
    }

    /// Opening a batch never touches a brew row, because it has no URL.
    func test_update_batchSkipsBrewRows() async {
        let opened = ActorBox<[URL]>([])
        let vm = makeViewModel(
            apps: [chromeApp],
            ownedTokens: ["Google Chrome.app": "google-chrome"],
            opened: opened
        )
        await vm.checkForUpdates()
        vm.setHomebrewOutdated([outdated(token: "google-chrome", from: "150.0", to: "151.0")])

        await vm.update(vm.availableUpdates)

        let urls = await opened.value
        XCTAssertTrue(urls.isEmpty, "A brew-managed row must never be opened")
    }

    // MARK: - Fixtures

    private var chromeApp: AppInfo {
        AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome", version: "150.0",
                bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"), isAppStore: false)
    }

    private var telegramApp: AppInfo {
        AppInfo(name: "Telegram", bundleID: "ru.keepcoder.telegram", version: "12.8",
                bundleURL: URL(fileURLWithPath: "/Applications/Telegram.app"), isAppStore: false)
    }

    private func outdated(
        token: String,
        from: String,
        to: String,
        pinned: Bool = false
    ) -> BrewOutdatedItem {
        BrewOutdatedItem(name: token, kind: .cask, installedVersion: from,
                         candidateVersion: to, isPinned: pinned)
    }

    private func makeViewModel(
        apps: [AppInfo],
        ownedTokens: [String: String],
        sparkleVersion: String? = nil,
        opened: ActorBox<[URL]>? = nil
    ) -> AppUpdaterViewModel {
        let casks = ownedTokens.map { CaskOwnership(token: $0.value, appNames: [$0.key]) }
        return AppUpdaterViewModel(
            discover: { _ in apps },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in
                guard let sparkleVersion else { return .skipped }
                return .found(SparkleAppcastItem(
                    shortVersion: sparkleVersion,
                    version: nil,
                    downloadURL: URL(string: "https://example.com/app.dmg")!
                ))
            },
            classifyUnchecked: { _ in .unmonitored },
            loadCaskOwnership: { CaskOwnershipMap(casks: casks) },
            opener: { url in await opened?.set((opened?.value ?? []) + [url]) }
        )
    }
}

private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}
