// HomebrewViewModelLoadTests.swift
// Verifies HomebrewViewModel availability gating, inventory loading, and the outdated-update dashboard.

import XCTest
@testable import VaderCleaner

@MainActor
final class HomebrewViewModelLoadTests: XCTestCase {

    private let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    private func makeViewModel(locatorURL: URL?, runner: StubBrewRunner) -> HomebrewViewModel {
        HomebrewViewModel(
            locator: StubBrewLocator(url: locatorURL),
            makeRunner: { _ in runner }
        )
    }

    func test_load_notInstalledWhenBrewMissing() async {
        let vm = makeViewModel(locatorURL: nil, runner: StubBrewRunner())
        await vm.load()
        XCTAssertEqual(vm.phase, .notInstalled)
        XCTAssertTrue(vm.inventory.isEmpty)
    }

    func test_load_emptyInventoryStaysReady() async {
        let vm = makeViewModel(locatorURL: brewURL, runner: StubBrewRunner())
        await vm.load()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.inventory.isEmpty)
    }

    func test_load_populatesFormulaeCasksAndLeafFlags() async {
        let runner = StubBrewRunner()
        runner.captures["leaves --installed-on-request"] = BrewResult(terminationStatus: 0, standardOutput: "git\n", standardError: "")
        runner.captures["list --formula --versions"] = BrewResult(terminationStatus: 0, standardOutput: "git 2.43.0\nreadline 8.2\n", standardError: "")
        runner.captures["list --cask --versions"] = BrewResult(terminationStatus: 0, standardOutput: "firefox 121.0\n", standardError: "")

        let vm = makeViewModel(locatorURL: brewURL, runner: runner)
        await vm.load()

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.inventory.count, 3)
        let git = vm.inventory.first { $0.name == "git" }
        let readline = vm.inventory.first { $0.name == "readline" }
        let firefox = vm.inventory.first { $0.name == "firefox" }
        XCTAssertEqual(git?.isLeaf, true)
        XCTAssertEqual(readline?.isLeaf, false)
        XCTAssertEqual(firefox?.kind, .cask)
        XCTAssertEqual(firefox?.isLeaf, true)
    }

    func test_load_failsWhenBrewErrors() async {
        let runner = StubBrewRunner()
        runner.throwingCaptures = ["leaves"]
        let vm = makeViewModel(locatorURL: brewURL, runner: runner)
        await vm.load()
        if case .failed = vm.phase {} else {
            XCTFail("expected .failed, got \(vm.phase)")
        }
    }

    func test_checkUpdates_populatesOutdatedWithCountsAndPinned() async {
        let runner = StubBrewRunner()
        let json = """
        {
          "formulae": [
            {"name": "node", "installed_versions": ["20.0.0"], "current_version": "21.0.0", "pinned": true},
            {"name": "wget", "installed_versions": ["1.21"], "current_version": "1.22", "pinned": false}
          ],
          "casks": []
        }
        """
        runner.captures["outdated --json=v2"] = BrewResult(terminationStatus: 0, standardOutput: json, standardError: "")

        let vm = makeViewModel(locatorURL: brewURL, runner: runner)
        await vm.load()
        await vm.checkUpdates()

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.availableUpdateCount, 2)
        XCTAssertEqual(vm.outdated.first { $0.name == "node" }?.isPinned, true)
    }

    func test_loadIfNeeded_loadsOnceThenNoOps() async {
        let runner = StubBrewRunner()
        runner.captures["list --formula --versions"] = BrewResult(terminationStatus: 0, standardOutput: "git 2.43.0\n", standardError: "")
        let vm = makeViewModel(locatorURL: brewURL, runner: runner)

        await vm.loadIfNeeded()
        XCTAssertEqual(vm.phase, .ready)
        let callsAfterFirst = runner.capturingCalls.count
        // A second call is a no-op — phase is no longer idle.
        await vm.loadIfNeeded()
        XCTAssertEqual(runner.capturingCalls.count, callsAfterFirst)
    }

    func test_checkUpdatesIfNeeded_runsOnceThenNoOps() async {
        let runner = StubBrewRunner()
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0,
            standardOutput: #"{"formulae": [{"name": "wget", "installed_versions": ["1.21"], "current_version": "1.22"}], "casks": []}"#,
            standardError: ""
        )
        let vm = makeViewModel(locatorURL: brewURL, runner: runner)
        await vm.load()

        await vm.checkUpdatesIfNeeded()
        XCTAssertEqual(vm.availableUpdateCount, 1)
        let outdatedCalls = runner.capturingCalls.filter { $0.first == "outdated" }.count
        XCTAssertEqual(outdatedCalls, 1)

        // Second call is a no-op — updates were already checked this session.
        await vm.checkUpdatesIfNeeded()
        XCTAssertEqual(runner.capturingCalls.filter { $0.first == "outdated" }.count, 1)
    }

    func test_checkUpdates_stillListsOutdatedWhenUpdateFails() async {
        let runner = StubBrewRunner()
        runner.throwingCaptures = ["update"]  // brew update fails (offline)
        runner.captures["outdated --json=v2"] = BrewResult(
            terminationStatus: 0,
            standardOutput: #"{"formulae": [{"name": "wget", "installed_versions": ["1.21"], "current_version": "1.22"}], "casks": []}"#,
            standardError: ""
        )
        let vm = makeViewModel(locatorURL: brewURL, runner: runner)
        await vm.load()
        await vm.checkUpdates()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.availableUpdateCount, 1)
    }
}
