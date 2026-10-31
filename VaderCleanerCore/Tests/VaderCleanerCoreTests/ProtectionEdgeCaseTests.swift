// ProtectionEdgeCaseTests.swift
// Pins the Protection edge cases where a result could overstate itself: stores with unflushed writes or nested unreadable folders, removals that can't look up their rows, coverage a scan didn't get to, and confirmations that have to name what they act on.

import Foundation
import SQLite3
import Testing
@testable import VaderCleanerCore

private struct StubPaths: BrowserDataPathProviding {
    let paths: [PrivacyCategory: [URL]]
    func dataPaths(for browser: Browser, category: PrivacyCategory) -> [URL] {
        paths[category] ?? []
    }
}

@Suite
struct BrowserPrivacyStoreEdgeCaseTests {

    @Test
    func rowsStillInTheWriteAheadLogAreCounted() async throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let cookies = root.appendingPathComponent("cookies.sqlite")
        // Held open with checkpointing off, the way a running browser leaves it,
        // so the row exists only in the -wal file.
        var writer: OpaquePointer?
        #expect(sqlite3_open(cookies.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        for sql in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA wal_autocheckpoint=0",
            "CREATE TABLE moz_cookies (host TEXT)",
            "INSERT INTO moz_cookies VALUES ('.a.com')"
        ] {
            #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        }
        let inspector = BrowserPrivacyInspector(pathProvider: StubPaths(paths: [.cookies: [cookies]]))

        #expect(await inspector.count(for: .cookies, browser: .firefox) == 1)
        #expect(await inspector.items(for: .cookies, browser: .firefox).map(\.id) == [".a.com"])
    }

    @Test
    func aNestedFolderThatCannotBeListedMakesTheCategoryUnreadable() async throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let cache = root.appendingPathComponent("Cache")
        let nested = cache.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: nested.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path) }
        let inspector = BrowserPrivacyInspector(pathProvider: StubPaths(paths: [.cache: [cache]]))

        #expect(await inspector.availability(for: .cachedFiles, browser: .chrome) == .unreadable)
    }

    @Test
    func aSiteRemovalThatCannotLookUpItsRowsIsReported() async throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }
        let history = root.appendingPathComponent("History")
        var db: OpaquePointer?
        #expect(sqlite3_open(history.path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE unrelated (id INTEGER)", nil, nil, nil)
        sqlite3_close(db)
        let remover = BrowserPrivacyRemover(
            pathProvider: StubPaths(paths: [.history: [history]]),
            isBrowserRunning: { _ in false }
        )

        await #expect(throws: PrivacyRemovalError.incomplete) {
            try await remover.remove([
                PrivacyRemovalRequest(browser: .chrome, category: .downloadsHistory, scope: .items(hostKeys: ["a.com"]))
            ])
        }
    }
}

@Suite
struct ClamAVScannerCoverageEdgeCaseTests {

    private func scanner(
        runner: @escaping ClamAVScanner.ScanRunner,
        newlinePaths: @escaping ClamAVScanner.NewlinePathFinder = { _, _ in [] },
        excludedDirectories: [String] = []
    ) -> ClamAVScanner {
        ClamAVScanner(
            detector: ClamAVDetector(
                candidatePaths: [URL(fileURLWithPath: "/opt/homebrew/bin/clamscan")],
                isExecutable: { _ in true },
                versionRunner: { _ in nil }
            ),
            runner: runner,
            databaseDirectoryProvider: { nil },
            excludedDirectories: excludedDirectories,
            progressThrottleInterval: 0,
            isRegularFile: { _ in true },
            newlinePathFinder: newlinePaths,
            selfTestsEngine: false
        )
    }

    @Test
    func aThreatUnreadableOnItsSecondLookCountsAsMissedCoverage() async throws {
        let confirmed = "/Users/me/a.bin"
        let vanished = "/Users/me/b.bin"
        let report = try await scanner(runner: { _, arguments, onLine in
            if arguments.contains("--recursive") {
                onLine("\(confirmed): Sig FOUND")
                onLine("\(vanished): Sig FOUND")
                return 1
            }
            onLine("\(confirmed): Sig FOUND")
            onLine("\(vanished): Access denied")
            return 2
        }).scanReport(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(report.threats.map(\.filePath.path) == [confirmed])
        #expect(report.unreadableCount == 1)
    }

    @Test
    func newlineFilesPastTheLimitCountAsMissedCoverage() async throws {
        let sample = "/Users/me/sample.bin"
        let extra = 2
        let newlinePaths = (0..<(ClamAVScanner.newlinePathCheckLimit + extra))
            .map { URL(fileURLWithPath: "/Users/me/n\($0)\nx") }
        let report = try await scanner(
            runner: { _, arguments, onLine in
                if arguments.contains("--recursive") {
                    onLine("\(sample): Sig FOUND")
                    onLine("x: Sig FOUND")
                    return 1
                }
                if arguments.last == sample {
                    onLine("\(sample): Sig FOUND")
                    return 1
                }
                return 0
            },
            newlinePaths: { _, _ in newlinePaths }
        ).scanReport(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(report.threats.map(\.filePath.path) == [sample])
        #expect(report.unreadableCount == extra)
    }

    @Test
    func theNewlineSearchIsGivenTheScansExclusions() async throws {
        let seen = TestBox<[String]>([])
        _ = try? await scanner(
            runner: { _, _, onLine in
                onLine("x: Sig FOUND")
                return 1
            },
            newlinePaths: { _, excluded in
                seen.value = excluded
                return []
            },
            excludedDirectories: ["/node_modules/"]
        ).scan(paths: [URL(fileURLWithPath: "/Users/me")], progress: { _, _ in })

        #expect(seen.value == ["/node_modules/"])
    }

    @Test
    func theDefaultNewlineSearchSkipsExcludedFolders() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("NewlineExclusions-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let excluded = root.appendingPathComponent("node_modules/deep")
        let ignored = root.appendingPathComponent("Ignored")
        try fileManager.createDirectory(at: excluded, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: excluded.appendingPathComponent("a\nb"))
        try Data("a".utf8).write(to: ignored.appendingPathComponent("c\nd"))
        try Data("a".utf8).write(to: root.appendingPathComponent("e\nf"))

        // The tail is the Ignore List's. Not anchored, because the walk reports the
        // temp folder under /private/var.
        let found = ClamAVScanner.defaultNewlinePathFinder([root], ["/node_modules/", "/Ignored(/|$)"])

        #expect(found.map(\.lastPathComponent) == ["e\nf"])
    }
}

@MainActor
@Suite
struct ProtectionPrivacyModelEdgeCaseTests {

    nonisolated private static let cookies = (1...5).map {
        PrivacyItem(id: "site\($0).com", label: "site\($0).com", count: 1, hostKey: "site\($0).com")
    }

    private func makeModel(
        count: @escaping ProtectionPrivacyModel.CountProvider = { _, _ in 3 },
        availability: @escaping ProtectionPrivacyModel.AvailabilityProvider = { _, _ in .available }
    ) -> ProtectionPrivacyModel {
        ProtectionPrivacyModel(
            detect: { [.chrome] },
            count: count,
            items: { _, category in category == .cookies ? ProtectionPrivacyModelEdgeCaseTests.cookies : [] },
            availability: availability,
            remove: { _ in }
        )
    }

    @Test
    func thePartialSummaryNamesTheChosenSites() async {
        let model = makeModel()
        await model.scan()
        model.toggleItem(.chrome, .cookies, "site1.com")

        #expect(model.removalSummaryLines == ["Google Chrome: Cookies (1 of 5: site1.com)"])
    }

    @Test
    func aLongPartialSummaryIsCutShort() async {
        let model = makeModel()
        await model.scan()
        for id in ["site1.com", "site2.com", "site3.com", "site4.com"] {
            model.toggleItem(.chrome, .cookies, id)
        }

        #expect(model.removalSummaryLines == ["Google Chrome: Cookies (4 of 5: site1.com, site2.com, site3.com, and 1 more)"])
    }

    @Test
    func aBrowserNotYetCountedReportsThatNothingWasRemoved() async {
        let model = makeModel()

        let removed = await model.removeAllData(for: .chrome)

        #expect(!removed)
        #expect(model.removalFailureMessage != nil)
    }

    @Test
    func anUnreadableStoreMeansTheBrowserIsNotClear() async {
        let model = makeModel(
            count: { _, category in category == .cookies ? 0 : 3 },
            availability: { _, category in category == .cookies ? .unreadable : .available }
        )
        await model.scan()

        let removed = await model.removeAllData(for: .chrome)

        #expect(!removed)
        #expect(model.removalFailureMessage != nil)
    }

    @Test
    func theConfirmationPromisesOnlyWhatThisBrowserCanRemove() async {
        let limited = makeModel(availability: { _, category in
            category == .cookies || category == .downloadsHistory ? .unsupported : .available
        })
        await limited.scan()
        let limitedMessage = limited.removalConfirmation(for: .chrome)
        #expect(limitedMessage.contains("cached files"))
        #expect(!limitedMessage.contains("cookies"))
        #expect(!limitedMessage.contains("downloads history"))
        #expect(!limitedMessage.contains("signs you out"))

        let full = makeModel()
        await full.scan()
        let fullMessage = full.removalConfirmation(for: .chrome)
        #expect(fullMessage.contains("cookies"))
        #expect(fullMessage.contains("downloads history"))
        #expect(fullMessage.contains("signs you out"))
    }

    @Test
    func theSelectMenuReflectsOnlyWhatSearchLeavesVisible() async {
        let model = makeModel()
        await model.scan()
        model.toggleItem(.chrome, .cookies, "site1.com")

        #expect(model.hasSelection(in: .chrome, search: ""))
        #expect(model.hasSelection(in: .chrome, search: "site1"))
        #expect(!model.hasSelection(in: .chrome, search: "site2"))
    }
}

@MainActor
@Suite
struct MalwareFlowEdgeCaseTests {

    private let threat = MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/a.bin"), threatName: "A")

    @Test
    func emptyingTheListElsewhereClearsAnEarlierRemovalFailure() async {
        let vm = MalwareViewModel(
            checkInstalled: { true },
            databaseLastUpdated: { Date() },
            updateDatabase: { _ in },
            scan: { _, _ in [] },
            removeThreats: { $0 },
            notify: { _ in },
            shouldNotify: { false }
        )
        vm.seed(threats: [threat], clamAVAvailable: true, scannedAt: Date())
        await vm.removeThreats([threat])
        #expect(vm.threatRemovalFailureCount == 1)

        vm.threatsRemovedElsewhere([threat])

        #expect(vm.threatRemovalFailureCount == 0)
    }

    @Test
    func aNewlineInAFileNameCannotAddLinesToTheConfirmation() {
        let threat = MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/evil\nharmless.txt"), threatName: "A")

        let message = [threat].namedRemovalConfirmationMessage

        #expect(message.contains("evil harmless.txt"))
        #expect(!message.contains("evil\nharmless.txt"))
    }

    @Test
    func aReminderDatedInTheFutureDoesNotSilenceTheNextOne() throws {
        let suite = "MalwareFlowEdgeCaseTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dispatcher = StubNotificationDispatcher()
        let clock = TestBox(Date(timeIntervalSince1970: 1_700_000_000))
        let monitor = MalwareDefinitionsMonitor(
            preferences: PreferencesStore(defaults: defaults),
            dispatcher: dispatcher,
            lastUpdateDate: { Date(timeIntervalSince1970: 1_000_000_000) },
            now: { clock.value },
            cooldownDefaults: defaults
        )
        monitor.evaluate()

        clock.value = clock.value.addingTimeInterval(-30 * 24 * 60 * 60)
        monitor.evaluate()

        #expect(dispatcher.calls.count == 2, "the clock moved back past the last reminder")
    }
}

@MainActor
@Suite
struct PrivacyViewModelRefreshTests {

    @Test
    func anOlderRefreshFinishingLastDoesNotOverwriteANewerOne() async {
        let gate = SuspendingCallGate()
        let holds = TestBox(false)
        let size = TestBox<Int64>(1)
        let vm = PrivacyViewModel(
            detector: { [.chrome] },
            sizer: { _, _ in
                let value = size.value
                if holds.value { await gate.hold() }
                return value
            },
            pathsFor: { _, category in [URL(fileURLWithPath: "/tmp/\(category.rawValue)")] },
            clearer: { _, _ in },
            clearRecentFiles: {}
        )
        await vm.preview()

        holds.value = true
        let older = Task { await vm.refreshSizes() }
        await Task.yield()
        #expect(await pollUntil { gate.isHolding })
        holds.value = false
        size.value = 7
        await vm.refreshSizes()
        #expect(vm.size(for: .chrome, category: .cache) == 7)

        size.value = 1
        gate.open()
        await older.value

        #expect(vm.size(for: .chrome, category: .cache) == 7)
    }

    @Test
    func aRefreshPicksUpAProfileThatAppearedSinceThePreview() async {
        let paths = TestBox<[URL]>([])
        let vm = PrivacyViewModel(
            detector: { [.firefox] },
            sizer: { _, _ in 100 },
            pathsFor: { _, _ in paths.value },
            clearer: { _, _ in },
            clearRecentFiles: {}
        )
        await vm.preview()
        #expect(vm.removableSize(for: .firefox) == 0)

        paths.value = [URL(fileURLWithPath: "/tmp/new-profile/cookies.sqlite")]
        await vm.refreshSizes()

        #expect(vm.removableSize(for: .firefox) == 100)
    }

    @Test
    func recentItemsCanBeRecheckedWithoutAPreview() async {
        let present = TestBox(false)
        let vm = PrivacyViewModel(
            detector: { [] },
            sizer: { _, _ in 0 },
            pathsFor: { _, _ in [] },
            clearer: { _, _ in },
            clearRecentFiles: {},
            recentItemsPresent: { present.value }
        )
        await vm.preview()
        present.value = true

        vm.refreshRecentItems()

        #expect(vm.hasRecentItems)
    }
}
