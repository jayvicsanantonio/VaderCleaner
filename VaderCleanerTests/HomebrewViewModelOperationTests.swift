// HomebrewViewModelOperationTests.swift
// Verifies HomebrewViewModel upgrade, dependency-aware uninstall, cleanup/autoremove, cancellation, and sudo/stall routing.

import XCTest
@testable import VaderCleaner

@MainActor
final class HomebrewViewModelOperationTests: XCTestCase {

    private let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    private func makeViewModel(runner: StubBrewRunner, stallTimeout: TimeInterval = 120) -> HomebrewViewModel {
        HomebrewViewModel(
            locator: StubBrewLocator(url: brewURL),
            makeRunner: { _ in runner },
            stallTimeout: stallTimeout
        )
    }

    private func outdatedJSON() -> String {
        """
        {
          "formulae": [
            {"name": "node", "installed_versions": ["20.0.0"], "current_version": "21.0.0", "pinned": true},
            {"name": "wget", "installed_versions": ["1.21"], "current_version": "1.22", "pinned": false}
          ],
          "casks": []
        }
        """
    }

    func test_upgradeAll_excludesPinned() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(terminationStatus: 0, standardOutput: outdatedJSON(), standardError: "")
        let vm = makeViewModel(runner: runner)
        await vm.load()
        await vm.checkUpdates()

        await vm.upgrade(.all)

        let upgradeCall = runner.streamingCalls.first { $0.first == "upgrade" }
        XCTAssertEqual(upgradeCall, ["upgrade", "wget"])  // node is pinned, excluded
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_upgradeSelected_upgradesExactly() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(terminationStatus: 0, standardOutput: outdatedJSON(), standardError: "")
        let vm = makeViewModel(runner: runner)
        await vm.load()
        await vm.checkUpdates()

        await vm.upgrade(.some(["wget"]))
        XCTAssertEqual(runner.streamingCalls.first { $0.first == "upgrade" }, ["upgrade", "wget"])
    }

    func test_upgrade_recordsFailureAndStaysReady() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(terminationStatus: 0, standardOutput: outdatedJSON(), standardError: "")
        runner.streams["upgrade wget"] = .init(lines: ["Error: wget failed"], status: 1)
        let vm = makeViewModel(runner: runner)
        await vm.load()
        await vm.checkUpdates()

        await vm.upgrade(.some(["wget"]))
        XCTAssertNotNil(vm.lastOperationError)
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_requestUninstall_withDependentsStagesConfirmation() async {
        let runner = StubBrewRunner()
        runner.captures["uses --installed openssl@3"] = BrewResult(terminationStatus: 0, standardOutput: "curl\nwget\n", standardError: "")
        let vm = makeViewModel(runner: runner)
        await vm.load()

        let openssl = BrewPackage(name: "openssl@3", kind: .formula, installedVersions: ["3.2.0"], isLeaf: false)
        await vm.requestUninstall([openssl])

        XCTAssertEqual(vm.pendingUninstall?.hasBlockingDependents, true)
        XCTAssertEqual(vm.pendingUninstall?.dependents["openssl@3"], ["curl", "wget"])
    }

    func test_requestUninstall_leafHasNoBlockingDependents() async {
        let runner = StubBrewRunner()  // uses returns empty by default
        let vm = makeViewModel(runner: runner)
        await vm.load()

        let git = BrewPackage(name: "git", kind: .formula, installedVersions: ["2.43.0"], isLeaf: true)
        await vm.requestUninstall([git])
        XCTAssertEqual(vm.pendingUninstall?.hasBlockingDependents, false)
    }

    func test_confirmUninstall_removesAndRefreshesAndOffersSweep() async {
        let runner = StubBrewRunner()
        let vm = makeViewModel(runner: runner)
        await vm.load()

        let git = BrewPackage(name: "git", kind: .formula, installedVersions: ["2.43.0"], isLeaf: true)
        await vm.requestUninstall([git])
        await vm.confirmUninstall()

        XCTAssertEqual(runner.streamingCalls.first { $0.first == "uninstall" }, ["uninstall", "git"])
        XCTAssertNil(vm.pendingUninstall)
        XCTAssertTrue(vm.postUninstallSweepAvailable)
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_confirmUninstall_caskWithSudoRoutesToTerminal() async {
        let runner = StubBrewRunner()
        runner.streams["uninstall --cask blender"] = .init(
            lines: ["==> Uninstalling Cask blender", "sudo: a terminal is required to read the password"],
            status: 1
        )
        let vm = makeViewModel(runner: runner)
        await vm.load()

        let blender = BrewPackage(name: "blender", kind: .cask, installedVersions: ["4.0"], isLeaf: true)
        await vm.requestUninstall([blender])
        await vm.confirmUninstall()

        XCTAssertEqual(vm.manualHandling?.command, "brew uninstall --cask blender")
    }

    func test_previewCleanup_readsReclaimableBytes() async {
        let runner = StubBrewRunner()
        runner.captures["cleanup -n"] = BrewResult(
            terminationStatus: 0,
            standardOutput: "==> This operation would free approximately 2.5GB of disk space.",
            standardError: ""
        )
        let vm = makeViewModel(runner: runner)
        await vm.load()
        await vm.previewCleanup()
        XCTAssertEqual(vm.reclaimablePreview, .bytes(Int64((2.5 * 1_073_741_824).rounded())))
    }

    func test_previewCleanup_unparseableIsUnavailable() async {
        let runner = StubBrewRunner()
        runner.captures["cleanup -n"] = BrewResult(terminationStatus: 0, standardOutput: "Nothing to do.", standardError: "")
        let vm = makeViewModel(runner: runner)
        await vm.load()
        await vm.previewCleanup()
        XCTAssertEqual(vm.reclaimablePreview, .unavailable)
    }

    func test_autoremove_reportsRemovedNames() async {
        let runner = StubBrewRunner()
        runner.streams["autoremove"] = .init(
            lines: ["==> Autoremoving 2 unneeded formulae:", "libyaml", "readline", "==> Uninstalling ..."],
            status: 0
        )
        let vm = makeViewModel(runner: runner)
        await vm.load()
        await vm.runAutoremove()
        XCTAssertEqual(vm.autoremovedNames, ["libyaml", "readline"])
        XCTAssertEqual(vm.phase, .ready)
    }

    func test_cancelActiveOperation_returnsToReady() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(terminationStatus: 0, standardOutput: outdatedJSON(), standardError: "")
        runner.hangingStreams = ["upgrade"]
        let vm = makeViewModel(runner: runner)  // large stall timeout so only cancel ends it
        await vm.load()
        await vm.checkUpdates()

        let task = Task { await vm.upgrade(.some(["wget"])) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        vm.cancelActiveOperation()
        await task.value

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNil(vm.manualHandling)
    }

    func test_stalledOperation_routesToManualHandling() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(terminationStatus: 0, standardOutput: outdatedJSON(), standardError: "")
        runner.hangingStreams = ["upgrade"]
        let vm = makeViewModel(runner: runner, stallTimeout: 0.3)
        await vm.load()
        await vm.checkUpdates()

        await vm.upgrade(.some(["wget"]))
        XCTAssertEqual(vm.manualHandling?.command, "brew upgrade wget")
        XCTAssertEqual(vm.phase, .ready)
    }
}
