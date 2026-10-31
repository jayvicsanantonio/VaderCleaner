// ApplicationsManagerReviewFollowUpTests.swift
// Pins the Applications Manager's handling of races and stale state: removals during scans and checks, retried installs, and notices that outlive what they describe.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite("Applications Manager races and stale state", .serialized)
@MainActor
struct ApplicationsManagerReviewFollowUpTests {

    private enum Failure: Error { case denied }

    @Test("a rescan clears the banner for an earlier removal")
    func scanClearsRemovalFailure() async {
        let a = URL(fileURLWithPath: "/tmp/a")
        let group = LeftoverGroup(bundleID: "com.acme.gone", displayName: "gone", urls: [a], totalBytes: 1)
        let vm = ApplicationsViewModel(
            discoverApps: { [] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in [group] },
            recycleFiles: { _ in [] }
        )
        await vm.scan()
        vm.toggleLeftover(group)
        await vm.deleteSelectedLeftovers()
        #expect(vm.notice != nil)
        await vm.scan()
        #expect(vm.notice == nil)
    }

    @Test("an app removed during a scan stays out of the results")
    func removalDuringScanIsExcluded() async throws {
        let target = app("A", id: "com.acme.a")
        let gate = RegressionGate()
        let vm = ApplicationsViewModel(
            discoverApps: {
                await gate.wait()
                return [target]
            },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in [] },
            recycleFiles: { _ in [] }
        )
        let scan = Task { await vm.scan() }
        #expect(await pollUntil { vm.phase == .scanning })
        vm.forgetApps([target.id])
        await gate.open()
        await scan.value
        guard case .results(let result) = vm.phase else {
            Issue.record("expected results")
            return
        }
        #expect(result.installedCount == 0)
    }

    @Test("a partly failed batch still says an app was permanently deleted")
    func partialBatchNamesPermanentDeletion() async throws {
        let good = app("Good", id: "com.acme.good")
        let bad = app("Bad", id: "com.acme.bad")
        let vm = AppUninstallerViewModel(
            discover: { _ in [good, bad] },
            findFiles: { _ in [] },
            recycle: { url, _ in
                if url.lastPathComponent == "Bad.app" { throw Failure.denied }
                return .init(bytesFreed: 1, bundlePermanentlyRemoved: true)
            }
        )
        await vm.loadApps()
        vm.toggleUninstallSelection(good.id)
        vm.toggleUninstallSelection(bad.id)
        await vm.uninstallSelected()
        let notice = try #require(vm.notice)
        #expect(notice.isError)
        #expect(notice.message.contains("Bad"))
        #expect(notice.message.localizedCaseInsensitiveContains("permanently"))
    }

    @Test("removing the other copy gives the open inspector its files back")
    func inspectorRefreshesWhenOtherCopyLeaves() async {
        let first = app("A", id: "com.acme.a", path: "/Applications/A.app")
        let second = app("A", id: "com.acme.a", path: "/Users/x/Applications/A.app")
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [first, second] },
            findFiles: { _ in [AssociatedFile(url: support, sizeBytes: 5, category: .applicationSupport)] },
            recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        vm.select(second.id)
        #expect(vm.associatedFilesByCategory.isEmpty)
        vm.toggleUninstallSelection(first.id)
        await vm.uninstallSelected()
        #expect(await pollUntil { !vm.associatedFilesByCategory.isEmpty && !vm.isLoadingAssociatedFiles })
    }

    @Test("an app removed during an update check doesn't come back with its results")
    func removalDuringCheckIsExcluded() async {
        let target = app("A", id: "com.acme.a")
        let gate = RegressionGate()
        let started = RegressionBox(false)
        let vm = AppUpdaterViewModel(
            discover: { _ in [target] },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in
                started.value = true
                await gate.wait()
                return .found(SparkleAppcastItem(
                    shortVersion: "2", version: nil, downloadURL: URL(string: "https://example.com/a.zip")!
                ))
            },
            opener: { _ in }
        )
        let check = Task { await vm.checkForUpdates() }
        #expect(await pollUntil { started.value })
        vm.forgetApps([target.id])
        await gate.open()
        await check.value
        #expect(vm.availableUpdates.isEmpty)
        #expect(vm.coverage.total == 0)
        #expect(vm.phase == .ready)
    }

    @Test("a cancelled retry doesn't leave the earlier failure on the row")
    func retryClearsEarlierFailure() async {
        let info = UpdateInfo(
            appName: "A",
            bundleID: "com.acme.a",
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            installedVersion: "1",
            latestVersion: "2",
            source: .sparkle,
            updateURL: URL(string: "https://example.com/a.zip")
        )
        let attempts = RegressionBox(0)
        let vm = AppUpdaterViewModel(
            discover: { _ in [] },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in .noResult },
            install: { _, _, _, _ in
                attempts.mutate { $0 += 1 }
                if attempts.value == 1 { return .failed("disk full") }
                while !Task.isCancelled { await Task.yield() }
                return .failed("cancelled")
            },
            opener: { _ in }
        )
        await vm.update([info])
        #expect(vm.installFailures[info.id] == "disk full")
        let retry = Task { await vm.update([info]) }
        #expect(await pollUntil { vm.installingIDs.contains(info.id) })
        vm.cancelInstall(info.id)
        await retry.value
        #expect(vm.installFailures[info.id] == nil)
    }

    @Test("a failed inventory reload stops offering the old upgrades")
    func failedReloadClearsOutdated() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0, standardOutput: outdatedJSON(casks: ["firefox"]), standardError: ""
        )
        let vm = brewVM(runner)
        await vm.load()
        await vm.checkUpdates()
        #expect(!vm.outdated.isEmpty)
        runner.throwingCaptures = ["list"]
        await vm.refresh()
        #expect(vm.outdated.isEmpty)
    }
}

@Suite("Applications Manager removal hand-off", .serialized)
@MainActor
struct ApplicationsManagerRemovalHandOffTests {

    @Test("a reload can't lose a removal the other panes haven't heard about")
    func reloadKeepsRemovalRecord() async {
        let target = app("A", id: "com.acme.a")
        let vm = AppUninstallerViewModel(
            discover: { _ in [] }, findFiles: { _ in [] }, recycle: { _, _ in noRecycle }
        )
        let seeded = AppUninstallerViewModel(
            discover: { _ in [target] }, findFiles: { _ in [] }, recycle: { _, _ in noRecycle }
        )
        await vm.loadApps()
        await seeded.loadApps()
        seeded.toggleUninstallSelection(target.id)
        await seeded.uninstallSelected()
        await seeded.loadApps()
        #expect(seeded.removedAppIDs == [target.id])
        #expect(seeded.consumeRemovedAppIDs() == [target.id])
        #expect(seeded.removedAppIDs.isEmpty)
        #expect(seeded.consumeRemovedAppIDs().isEmpty)
    }

    @Test("the scan's removal record is handed over once and survives a rescan")
    func scanRemovalRecord() async {
        let target = app("A", id: "com.acme.a")
        let entry = UnsupportedApp(app: target, reason: .incompatibleArchitecture)
        let vm = ApplicationsViewModel(
            discoverApps: { [target] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [entry] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in [] },
            recycleFiles: { Set($0) }
        )
        await vm.scan()
        vm.toggleUnsupportedApp(entry)
        await vm.deleteSelectedUnsupportedApps()
        await vm.scan()
        #expect(vm.consumeRemovedAppIDs() == [target.id])
        #expect(vm.removedAppIDs.isEmpty)
    }
}

@Suite("Update install tool limits", .serialized)
struct UpdateInstallToolLimitTests {

    private let tools = UpdateInstallTools(
        workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )

    @Test("a tool past its timeout is terminated rather than waited on")
    func timeoutTerminatesTool() async {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: (any Error).self) {
            try await tools.run("/bin/sleep", ["30"], timeout: .milliseconds(100))
        }
        #expect(started.duration(to: clock.now) < .seconds(10))
    }

    @Test("cancelling terminates a running tool")
    func cancelTerminatesTool() async {
        let clock = ContinuousClock()
        let started = clock.now
        let tools = tools
        let run = Task { try await tools.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(for: .milliseconds(100))
        run.cancel()
        await #expect(throws: (any Error).self) { try await run.value }
        #expect(started.duration(to: clock.now) < .seconds(10))
    }

    @Test("a tool that finishes in time succeeds")
    func toolWithinTimeout() async throws {
        try await tools.run("/usr/bin/true", [], timeout: .seconds(30))
    }
}
