// AppUpdaterInstallTests.swift
// Drives the Updater's install-first behaviour — installing in place when allowed, falling back to a download when refused, and leaving the App Store and Homebrew channels alone.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdaterInstallTests: XCTestCase {

    /// The button says Update, so an installable update is installed —
    /// opening a download is the fallback, not the goal.
    func test_update_installsSparkleUpdateInPlaceWithoutOpeningADownload() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(outcome: .installed, opened: opened)

        await vm.update(vm.availableUpdates)

        let urls = await opened.value
        XCTAssertTrue(urls.isEmpty, "An installed update must not also open a download")
        XCTAssertTrue(vm.availableUpdates.isEmpty, "An installed update leaves the list")
    }

    /// A refused install still gets the user their update, by the old
    /// route. Every denial has a safe fallback.
    func test_update_fallsBackToDownloadWhenInstallIsRefused() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(outcome: .denied(.signatureUnverifiable), opened: opened)

        await vm.update(vm.availableUpdates)

        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://example.com/helio.zip")!])
    }

    /// The reason is recorded so the row can say the install was declined
    /// rather than silently doing something other than what was asked.
    func test_update_recordsWhyAnInstallWasRefused() async {
        let vm = await readyViewModel(outcome: .denied(.teamIdentifierMismatch), opened: ActorBox([]))
        let id = vm.availableUpdates[0].id

        await vm.update(vm.availableUpdates)

        XCTAssertEqual(vm.installFallbacks[id], .teamIdentifierMismatch)
    }

    /// A failure is not a denial: nothing was refused, something broke, so
    /// no refusal reason is shown — but the download still happens.
    func test_update_failedInstallFallsBackWithoutRecordingADenial() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(outcome: .failed("network"), opened: opened)
        let id = vm.availableUpdates[0].id

        await vm.update(vm.availableUpdates)

        XCTAssertNil(vm.installFallbacks[id])
        let urls = await opened.value
        XCTAssertEqual(urls.count, 1)
    }

    /// Without an installer configured the Updater behaves exactly as it
    /// did before — auto-install is additive, never a prerequisite.
    func test_update_withoutInstallerOpensTheDownload() async {
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(outcome: nil, opened: opened)

        await vm.update(vm.availableUpdates)

        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://example.com/helio.zip")!])
    }

    /// Auto-install is opt-in. With the preference off the installer is
    /// never consulted at all — the Updater downloads exactly as it did
    /// before in-place installs existed.
    func test_update_doesNotInstallWhenThePreferenceIsOff() async {
        let attempted = ActorBox(0)
        let opened = ActorBox<[URL]>([])
        let vm = await readyViewModel(
            outcome: .installed,
            opened: opened,
            autoInstallEnabled: false,
            onInstallAttempt: { await attempted.increment() }
        )

        await vm.update(vm.availableUpdates)

        let count = await attempted.value
        XCTAssertEqual(count, 0, "The installer must not run when the preference is off")
        let urls = await opened.value
        XCTAssertEqual(urls, [URL(string: "https://example.com/helio.zip")!])
    }

    /// App Store updates are Apple's to install; we never try to swap one.
    func test_update_neverAttemptsToInstallAnAppStoreUpdate() async {
        let attempted = ActorBox(0)
        let app = AppInfo(name: "Helio", bundleID: "com.acme.helio", version: "1.0",
                          bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"), isAppStore: true)
        let vm = AppUpdaterViewModel(
            discover: { _ in [app] },
            checkAppStore: { _ in
                .found(AppStoreLookup(version: "2.0",
                                      appStoreURL: URL(string: "https://apps.apple.com/app/id1")!))
            },
            checkSparkle: { _ in .skipped },
            classifyUnchecked: { _ in .unmonitored },
            install: { _, _, _ in await attempted.increment(); return .installed },
            opener: { _ in }
        )
        await vm.checkForUpdates()

        await vm.update(vm.availableUpdates)

        let count = await attempted.value
        XCTAssertEqual(count, 0)
    }

    // MARK: - Fixtures

    private func readyViewModel(
        outcome: UpdateInstallOutcome?,
        opened: ActorBox<[URL]>,
        autoInstallEnabled: Bool = true,
        onInstallAttempt: (@Sendable () async -> Void)? = nil
    ) async -> AppUpdaterViewModel {
        let app = AppInfo(name: "Helio", bundleID: "com.acme.helio", version: "1.0",
                          bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"), isAppStore: false)
        let vm = AppUpdaterViewModel(
            discover: { _ in [app] },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in
                .found(SparkleAppcastItem(
                    shortVersion: "2.0", version: nil,
                    downloadURL: URL(string: "https://example.com/helio.zip")!,
                    edSignature: "c2ln"
                ))
            },
            classifyUnchecked: { _ in .unmonitored },
            install: outcome.map { result -> AppUpdaterViewModel.Install in
                { _, _, _ in
                    await onInstallAttempt?()
                    return result
                }
            },
            readSigningInputs: { _ in (URL(string: "https://example.com/appcast.xml"), "key") },
            isAutoInstallEnabled: { autoInstallEnabled },
            opener: { url in await opened.set(opened.value + [url]) }
        )
        await vm.checkForUpdates()
        return vm
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
