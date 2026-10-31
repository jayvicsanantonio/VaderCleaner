// ApplicationsManagerInstallAndDiscoveryTests.swift
// Pins the Applications Manager fixes in update installs, download limits, app discovery, and the extension and list labels.

import Foundation
import Testing
@testable import VaderCleanerCore

// MARK: - Installs

@Suite("Applications Manager update installs", .serialized)
@MainActor
struct ApplicationsManagerInstallTests {

    private let info = UpdateInfo(
        appName: "A",
        bundleID: "com.acme.a",
        bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
        installedVersion: "1",
        latestVersion: "2",
        source: .sparkle,
        updateURL: URL(string: "https://example.com/a.zip")
    )

    private func updater(
        opened: RegressionBox<[URL]>,
        install: @escaping AppUpdaterViewModel.Install
    ) -> AppUpdaterViewModel {
        AppUpdaterViewModel(
            discover: { _ in [] },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in .noResult },
            install: install,
            opener: { url in opened.mutate { $0.append(url) } }
        )
    }

    @Test("a failed install keeps its reason for the row")
    func failureReasonKept() async {
        let vm = updater(opened: RegressionBox([]), install: { _, _, _, _ in .failed("disk full") })
        await vm.update([info])
        #expect(vm.installFailures[info.id] == "disk full")
    }

    @Test("cancelling an install stops it without opening a download")
    func cancelStopsInstall() async {
        let opened = RegressionBox<[URL]>([])
        let vm = updater(opened: opened, install: { _, _, _, _ in
            while !Task.isCancelled { await Task.yield() }
            return .failed("cancelled")
        })
        let run = Task { await vm.update([info]) }
        #expect(await pollUntil { vm.installingIDs.contains(info.id) })
        vm.cancelInstall(info.id)
        await run.value
        #expect(opened.value.isEmpty)
        #expect(vm.installFailures[info.id] == nil)
        #expect(vm.installingIDs.isEmpty)
    }

    @Test("download progress reaches the row and clears when done")
    func progressReported() async {
        let gate = RegressionGate()
        let vm = updater(opened: RegressionBox([]), install: { _, _, _, onProgress in
            onProgress(0.5)
            await gate.wait()
            return .installed
        })
        let run = Task { await vm.update([info]) }
        #expect(await pollUntil { vm.installProgress[info.id] == 0.5 })
        await gate.open()
        await run.value
        #expect(vm.installProgress[info.id] == nil)
    }

    @Test("a finished install is counted so the app list can re-read versions")
    func installCounted() async {
        let vm = updater(opened: RegressionBox([]), install: { _, _, _, _ in .installed })
        await vm.update([info])
        #expect(vm.completedInstallCount == 1)
    }
}

/// Serves canned bytes to an install download, with no network.
private final class StubDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var redirectTo: URL?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if let target = Self.redirectTo, request.url != target {
            let redirect = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Update download limits", .serialized)
struct UpdateDownloadLimitTests {

    private func tools(limit: Int64, directory: URL) -> UpdateInstallTools {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadProtocol.self]
        return UpdateInstallTools(
            workingDirectory: directory,
            sessionConfiguration: configuration,
            maximumBytes: limit
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("an oversized download is refused and leaves nothing behind")
    func oversizedRefused() async throws {
        StubDownloadProtocol.statusCode = 200
        StubDownloadProtocol.body = Data(count: 1000)
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: UpdateDownloadTooLarge.self) {
            _ = try await tools(limit: 100, directory: directory)
                .download(URL(string: "https://example.com/a.zip")!)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("update.zip").path))
    }

    @Test("a download within the limit lands in the working directory")
    func withinLimit() async throws {
        StubDownloadProtocol.statusCode = 200
        StubDownloadProtocol.body = Data(count: 50)
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await tools(limit: 100, directory: directory)
            .download(URL(string: "https://example.com/a.zip")!)
        #expect(file.lastPathComponent == "update.zip")
        #expect(try Data(contentsOf: file).count == 50)
    }

    @Test("a redirect to plain http is refused before any bytes land")
    func insecureRedirectRefused() async {
        StubDownloadProtocol.statusCode = 200
        StubDownloadProtocol.body = Data(count: 10)
        StubDownloadProtocol.redirectTo = URL(string: "http://example.com/a.zip")
        defer { StubDownloadProtocol.redirectTo = nil }
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: UpdateDownloadInsecureRedirect.self) {
            _ = try await tools(limit: 100, directory: directory)
                .download(URL(string: "https://example.com/a.zip")!)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("update.zip").path))
    }

    @Test("a redirect that stays on https is followed")
    func secureRedirectFollowed() async throws {
        StubDownloadProtocol.statusCode = 200
        StubDownloadProtocol.body = Data(count: 10)
        StubDownloadProtocol.redirectTo = URL(string: "https://cdn.example.com/a.zip")
        defer { StubDownloadProtocol.redirectTo = nil }
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await tools(limit: 100, directory: directory)
            .download(URL(string: "https://example.com/a.zip")!)
        #expect(try Data(contentsOf: file).count == 10)
    }

    @Test("an HTTP error isn't treated as a downloaded archive")
    func httpErrorRefused() async throws {
        StubDownloadProtocol.statusCode = 404
        StubDownloadProtocol.body = Data(count: 10)
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) {
            _ = try await tools(limit: 100, directory: directory)
                .download(URL(string: "https://example.com/a.zip")!)
        }
    }
}

// MARK: - Discovery and display

@Suite("Applications Manager discovery and display")
struct ApplicationsManagerDiscoveryTests {

    private func makeBundle(
        _ name: String,
        id: String,
        in root: URL,
        withReceipt: Bool = false
    ) throws {
        let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if withReceipt {
            let receipt = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
        }
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Apple apps the user installed are listed; the OS's own are not")
    func userInstalledAppleApps() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle("Pages", id: "com.apple.iWork.Pages", in: root, withReceipt: true)
        try makeBundle("Xcode", id: "com.apple.dt.Xcode", in: root)
        try makeBundle("Safari", id: "com.apple.Safari", in: root)
        let discovery = DefaultAppDiscovery(additionalRoots: [root], useDefaultRoots: false, lastUsedDate: { _ in nil })
        let names = try await discovery.installedApps(includingSystemApps: false).map(\.name)
        #expect(names == ["Pages", "Xcode"])
    }

    @Test("an iOS app wrapped for the Mac is discovered")
    func wrappedIOSApp() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("Game.app", isDirectory: true)
        let inner = wrapper.appendingPathComponent("Wrapper/Game.app", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.acme.game", "CFBundleDisplayName": "Game"], format: .xml, options: 0
        )
        try plist.write(to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            atPath: wrapper.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Game.app"
        )
        let discovery = DefaultAppDiscovery(additionalRoots: [root], useDefaultRoots: false, lastUsedDate: { _ in nil })
        let apps = try await discovery.installedApps(includingSystemApps: false)
        #expect(apps.map(\.bundleID) == ["com.acme.game"])
        #expect(apps.first?.isAppStore == true)
    }

    @Test("the Ignore List applies to the unsupported scan")
    func unsupportedHonoursExclusions() async {
        let kept = app("Kept", id: "com.acme.kept", path: "/Applications/Kept.app")
        let ignored = app("Ignored", id: "com.acme.ignored", path: "/Applications/Old/Ignored.app")
        let scanner = DefaultUnsupportedAppScanner(cpuTypesForApp: { _ in [0x0000_0007] })
        let found = await scanner.scan(
            apps: [kept, ignored],
            excluding: [URL(fileURLWithPath: "/Applications/Old")]
        )
        #expect(found.map(\.app.bundleID) == ["com.acme.kept"])
    }

    @Test("the architecture check depends on the Mac it runs on")
    func architecturePerMac() {
        let intel: Set<UInt32> = [MachOCPUType.x86_64]
        let appleSilicon: Set<UInt32> = [MachOCPUType.arm64, MachOCPUType.x86_64]
        #expect(UnsupportedAppClassifier.isUnsupported(cpuTypes: [MachOCPUType.arm64], runnable: intel))
        #expect(!UnsupportedAppClassifier.isUnsupported(cpuTypes: [MachOCPUType.arm64], runnable: appleSilicon))
        #expect(!UnsupportedAppClassifier.isUnsupported(cpuTypes: [MachOCPUType.x86_64], runnable: appleSilicon))
    }

    @Test("the Mac's own hardware decides, even for a process under Rosetta")
    func runnableTypesFollowHardware() {
        #expect(UnsupportedAppClassifier.runnableTypes(hostHasARM64: true) == [MachOCPUType.arm64, MachOCPUType.x86_64])
        #expect(UnsupportedAppClassifier.runnableTypes(hostHasARM64: false) == [MachOCPUType.x86_64])
        #expect(UnsupportedAppClassifier.runnableCPUTypes.contains(MachOCPUType.x86_64))
        #if arch(arm64)
        #expect(UnsupportedAppClassifier.runnableCPUTypes.contains(MachOCPUType.arm64))
        #endif
    }

    @Test("name summaries cut off and say how many more")
    func nameSummary() {
        #expect(ApplicationsManagerModel.nameSummary(["A", "B"]) == "A, B")
        #expect(ApplicationsManagerModel.nameSummary(["A", "B", "C"], limit: 2) == "A, B, and 1 more")
    }

    @Test("the bulk-select label counts every row, not just the visible ones")
    func bulkSelectState() {
        #expect(ApplicationsManagerModel.bulkSelectState(selected: 0, total: 3) == .none)
        #expect(ApplicationsManagerModel.bulkSelectState(selected: 1, total: 3) == .some)
        #expect(ApplicationsManagerModel.bulkSelectState(selected: 3, total: 3) == .all)
        #expect(ApplicationsManagerModel.bulkSelectState(selected: 0, total: 0) == .none)
    }

    @Test("empty lists explain themselves by why they are empty")
    func emptyReason() {
        #expect(ApplicationsManagerModel.emptyReason(search: " wget ", showsOnlySelected: false) == .noSearchMatches)
        #expect(ApplicationsManagerModel.emptyReason(search: "wget", showsOnlySelected: true) == .noSearchMatches)
        #expect(ApplicationsManagerModel.emptyReason(search: "  ", showsOnlySelected: true) == .nothingSelected)
        #expect(ApplicationsManagerModel.emptyReason(search: "", showsOnlySelected: false) == .nothingFound)
    }

    private func discoveryHome() throws -> URL { try scratch() }

    @Test("browser extensions carry their profile, and Firefox rows their real name")
    func extensionLabels() async throws {
        let home = try discoveryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let chromeVersion = support.appendingPathComponent("Google/Chrome/Profile 1/Extensions/abc/1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: chromeVersion, withIntermediateDirectories: true)
        try Data(#"{"name":"Blocker"}"#.utf8).write(to: chromeVersion.appendingPathComponent("manifest.json"))
        let temp = support.appendingPathComponent("Google/Chrome/Profile 1/Extensions/Temp/scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let firefox = support.appendingPathComponent("Firefox/Profiles/x1y2.default-release", isDirectory: true)
        let firefoxExtensions = firefox.appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: firefoxExtensions, withIntermediateDirectories: true)
        try Data().write(to: firefoxExtensions.appendingPathComponent("ublock@acme.xpi"))
        try Data(#"{"addons":[{"id":"ublock@acme","defaultLocale":{"name":"uBlock Origin"}}]}"#.utf8)
            .write(to: firefox.appendingPathComponent("extensions.json"))

        let items = await BrowserExtensionDiscovery(homeDirectory: home).extensions()
        #expect(items.map(\.name).sorted() == ["Blocker", "uBlock Origin"])
        #expect(items.first { $0.name == "Blocker" }?.profile == "Profile 1")
        #expect(items.first { $0.name == "uBlock Origin" }?.profile == "default-release")
    }
}
