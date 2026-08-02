// CaskOwnershipLoaderTests.swift
// Drives the loader that builds the cask ownership map from `brew info --json=v2 --installed` plus a Caskroom listing, including every degradation path that must yield an empty map rather than a wrong one.

import XCTest
@testable import VaderCleaner

final class CaskOwnershipLoaderTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempDirectory)
        tempDirectory = nil
    }

    /// The happy path: brew's inventory becomes an ownership map that
    /// matches a discovered bundle.
    func test_load_buildsMapFromBrewInventory() async throws {
        let runner = StubBrewRunner()
        runner.captures["info --json=v2 --installed"] = BrewResult(
            terminationStatus: 0,
            standardOutput: #"{"casks":[{"token":"vlc","auto_updates":true,"artifacts":[{"app":["VLC.app"]}]}]}"#,
            standardError: ""
        )

        let map = await makeLoader(runner: runner).load()

        XCTAssertEqual(map.owner(of: app(named: "VLC.app"))?.token, "vlc")
    }

    /// The exact argument list matters — `--installed` is what keeps brew
    /// from describing its entire catalogue.
    func test_load_invokesInfoWithInstalledOnly() async {
        let runner = StubBrewRunner()
        runner.captures["info --json=v2 --installed"] = BrewResult(
            terminationStatus: 0, standardOutput: #"{"casks":[]}"#, standardError: ""
        )

        _ = await makeLoader(runner: runner).load()

        XCTAssertEqual(runner.capturingCalls, [["info", "--json=v2", "--installed"]])
    }

    /// Without Homebrew there is nothing to own, and no subprocess should
    /// be attempted.
    func test_load_withoutHomebrewYieldsEmptyMap() async {
        let loader = CaskOwnershipLoader(
            locator: StubBrewLocator(url: nil),
            makeRunner: { _ in
                XCTFail("No runner should be built when brew is absent")
                return StubBrewRunner()
            }
        )
        let map = await loader.load()
        XCTAssertNil(map.owner(of: app(named: "VLC.app")))
        XCTAssertTrue(map.unresolvedTokens.isEmpty)
    }

    /// A non-zero exit yields an empty map. Claiming ownership from a
    /// failed inventory would suppress real updates.
    func test_load_brewFailureYieldsEmptyMap() async {
        let runner = StubBrewRunner()
        runner.captures["info --json=v2 --installed"] = BrewResult(
            terminationStatus: 1, standardOutput: "", standardError: "boom"
        )
        let map = await makeLoader(runner: runner).load()
        XCTAssertNil(map.owner(of: app(named: "VLC.app")))
    }

    /// A runner that cannot launch degrades the same way.
    func test_load_runnerThrowsYieldsEmptyMap() async {
        let runner = StubBrewRunner()
        runner.throwingCaptures = ["info --json=v2 --installed"]
        let map = await makeLoader(runner: runner).load()
        XCTAssertNil(map.owner(of: app(named: "VLC.app")))
    }

    /// Unparseable output yields an empty map rather than propagating.
    /// The Updater degrades to offering downloads, which is the behaviour
    /// it had before ownership existed — not a new failure mode.
    func test_load_malformedJSONYieldsEmptyMap() async {
        let runner = StubBrewRunner()
        runner.captures["info --json=v2 --installed"] = BrewResult(
            terminationStatus: 0, standardOutput: "not json", standardError: ""
        )
        let map = await makeLoader(runner: runner).load()
        XCTAssertNil(map.owner(of: app(named: "VLC.app")))
    }

    // MARK: - Caskroom cross-check

    /// Caskroom directory names are read relative to the brew prefix
    /// derived from the binary path, and tokens brew didn't describe are
    /// reported.
    func test_load_reportsCaskroomTokensMissingFromInventory() async throws {
        let prefix = tempDirectory.appendingPathComponent("homebrew", isDirectory: true)
        let caskroom = prefix.appendingPathComponent("Caskroom", isDirectory: true)
        for token in ["vlc", "docker", "windsurf"] {
            try FileManager.default.createDirectory(
                at: caskroom.appendingPathComponent(token, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let runner = StubBrewRunner()
        runner.captures["info --json=v2 --installed"] = BrewResult(
            terminationStatus: 0,
            standardOutput: #"{"casks":[{"token":"vlc","artifacts":[{"app":["VLC.app"]}]}]}"#,
            standardError: ""
        )

        let loader = CaskOwnershipLoader(
            locator: StubBrewLocator(
                url: prefix.appendingPathComponent("bin/brew")
            ),
            makeRunner: { _ in runner }
        )
        let map = await loader.load()

        XCTAssertEqual(map.unresolvedTokens, ["docker", "windsurf"])
        XCTAssertEqual(map.owner(of: app(named: "VLC.app"))?.token, "vlc")
    }

    /// A missing Caskroom directory is not an error — it just means there
    /// is nothing to cross-check against.
    func test_load_absentCaskroomYieldsNoUnresolvedTokens() async {
        let runner = StubBrewRunner()
        runner.captures["info --json=v2 --installed"] = BrewResult(
            terminationStatus: 0,
            standardOutput: #"{"casks":[{"token":"vlc","artifacts":[{"app":["VLC.app"]}]}]}"#,
            standardError: ""
        )
        let map = await makeLoader(runner: runner).load()
        XCTAssertTrue(map.unresolvedTokens.isEmpty)
    }

    // MARK: - Helpers

    /// Loader pointed at a brew binary under the temp directory, so the
    /// derived prefix stays inside the fixture.
    private func makeLoader(runner: StubBrewRunner) -> CaskOwnershipLoader {
        CaskOwnershipLoader(
            locator: StubBrewLocator(
                url: tempDirectory
                    .appendingPathComponent("homebrew", isDirectory: true)
                    .appendingPathComponent("bin/brew")
            ),
            makeRunner: { _ in runner }
        )
    }

    private func app(named bundleName: String) -> AppInfo {
        AppInfo(
            name: bundleName,
            bundleID: "com.acme.fixture",
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleName)"),
            isAppStore: false
        )
    }
}
