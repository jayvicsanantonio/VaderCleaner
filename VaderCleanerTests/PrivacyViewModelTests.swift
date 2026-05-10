// PrivacyViewModelTests.swift
// Tests the PrivacyViewModel state machine, default selection, deduplication, and clear dispatch — driving every transition through injected fake browsers, sizers, and clearers so no real browser data is touched.

import XCTest
import Combine
@testable import VaderCleaner

@MainActor
final class PrivacyViewModelTests: XCTestCase {

    // MARK: - Initial state

    /// On construction the VM must be in `.idle` so the Privacy view shows
    /// its "Scan" call-to-action — not a stale preview from a prior session.
    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
    }

    // MARK: - Preview transitions

    /// `preview()` must advance from `.idle` through `.scanning` to
    /// `.preview` once the injected sizer / detector resolve. The
    /// transient `.scanning` value is what drives the spinner; without
    /// asserting on it the VM could jump straight to `.preview` and the
    /// view would render nothing during a slow scan.
    func test_preview_transitionsIdleToScanningToPreview() async {
        let vm = makeViewModel(
            detected: [.safari, .chrome],
            sizer: { _, _ in 100 }
        )

        var phases: [PrivacyViewModel.Phase] = []
        let cancellable = vm.$phase.sink { phases.append($0) }

        await vm.preview()
        cancellable.cancel()

        XCTAssertEqual(phases.first, .idle)
        XCTAssertTrue(phases.contains(.scanning))
        if case .preview = vm.phase {
            // expected
        } else {
            XCTFail("Expected .preview, got \(vm.phase)")
        }
    }

    /// Every `(browser, category)` pair from the detected browsers must
    /// be checked by default — the user opts out of categories rather
    /// than opting in, mirroring System Junk's behavior.
    func test_preview_marksEverySelectionCheckedByDefault() async {
        let vm = makeViewModel(
            detected: [.safari, .chrome],
            sizer: { _, _ in 100 }
        )

        await vm.preview()

        for browser in [Browser.safari, .chrome] {
            for category in PrivacyCategory.allCases {
                XCTAssertTrue(vm.isChecked(browser: browser, category: category),
                              "Expected (\(browser), \(category)) checked by default")
            }
        }
        XCTAssertTrue(vm.isClearRecentsChecked,
                      "Recent items toggle must default to checked")
    }

    /// Per-category sizes must be exposed for the view to render
    /// "20 MB"-style labels next to each checkbox without recomputing
    /// from scratch on every redraw.
    func test_preview_exposesPerCategorySizes() async {
        let vm = makeViewModel(
            detected: [.chrome],
            sizer: { browser, category in
                browser == .chrome && category == .cache ? 1_024 * 1_024 : 100
            }
        )

        await vm.preview()

        XCTAssertEqual(vm.size(for: .chrome, category: .cache), 1_024 * 1_024)
        XCTAssertEqual(vm.size(for: .chrome, category: .history), 100)
    }

    /// A throwing detector must surface `.failed` rather than leaving the
    /// VM stuck in `.scanning` — otherwise the spinner never resolves.
    func test_preview_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(
            detector: { throw BoomError() },
            sizer: { _, _ in 0 }
        )

        await vm.preview()

        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    /// A slow async sizer must yield the main actor while filesystem work is
    /// in flight. This protects the SwiftUI spinner / repaint loop from
    /// being pinned by Privacy preview work.
    func test_preview_yieldsMainActorWhileSizingIsSuspended() async {
        let sizerStarted = expectation(description: "sizer started")
        let mainActorWasFree = expectation(description: "main actor accepted another task")
        var didSuspendSizer = false
        var releaseSizer: CheckedContinuation<Void, Never>?
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in
                if !didSuspendSizer {
                    didSuspendSizer = true
                    sizerStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseSizer = continuation
                    }
                }
                return 1
            }
        )

        let previewTask = Task { await vm.preview() }
        await fulfillment(of: [sizerStarted], timeout: 1)
        Task { @MainActor in mainActorWasFree.fulfill() }
        await fulfillment(of: [mainActorWasFree], timeout: 1)

        releaseSizer?.resume()
        await previewTask.value
        XCTAssertEqual(vm.phase, .preview)
    }

    /// Starting a fresh preview must cancel the old one and ignore any stale
    /// result it might try to publish after cancellation unwinds.
    func test_preview_restartCancelsInFlightScanAndKeepsLatestResult() async {
        let firstSizerStarted = expectation(description: "first sizer started")
        var detectorCalls = 0
        var sizerCalls = 0
        let vm = makeViewModel(
            detector: {
                detectorCalls += 1
                return detectorCalls == 1 ? [.safari] : [.chrome]
            },
            sizer: { _, _ in
                sizerCalls += 1
                if sizerCalls == 1 {
                    firstSizerStarted.fulfill()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return 25
            }
        )

        let firstPreview = Task { await vm.preview() }
        await fulfillment(of: [firstSizerStarted], timeout: 1)

        let secondPreview = Task { await vm.preview() }
        await secondPreview.value
        await firstPreview.value

        XCTAssertEqual(vm.phase, .preview)
        XCTAssertEqual(vm.detectedBrowsers, [.chrome])
        XCTAssertEqual(vm.size(for: .chrome, category: .history), 25)
    }

    // MARK: - Actionability

    /// `isCategoryActionable` is the contract the view uses to decide
    /// whether to render a row as a checkbox or as an informational
    /// "Included with Browsing History" caption. A category with no
    /// paths must report unactionable so the UI never offers a
    /// control that does nothing — Codex flagged this as a P2 on
    /// PR #39.
    func test_isCategoryActionable_returnsFalseWhenPathsResolverEmpty() async {
        let vm = makeViewModel(
            detected: [.chrome],
            sizer: { _, _ in 100 },
            pathsFor: { _, category in
                category == .history
                    ? [URL(fileURLWithPath: "/tmp/vctests/Chrome/Default/History")]
                    : []
            }
        )
        await vm.preview()

        XCTAssertTrue(vm.isCategoryActionable(browser: .chrome, category: .history))
        XCTAssertFalse(vm.isCategoryActionable(browser: .chrome, category: .downloads))
        XCTAssertFalse(vm.isCategoryActionable(browser: .chrome, category: .cookies))
    }

    /// Production wiring: `.downloads` must be unactionable for every
    /// Chromium / Firefox browser so the UI couples the row visually
    /// to History. Safari's `.downloads` is independently clearable
    /// (`Downloads.plist`) and must remain actionable.
    func test_isCategoryActionable_decouplesChromiumDownloads() async {
        let vm = makeViewModel(
            detected: [.safari, .chrome, .firefox, .brave, .arc, .opera, .edge],
            sizer: { _, _ in 0 },
            pathsFor: { browser, category in
                DefaultBrowserDataPathProvider(homeDirectory: URL(fileURLWithPath: "/tmp/vctests"))
                    .dataPaths(for: browser, category: category)
            }
        )
        await vm.preview()

        XCTAssertTrue(vm.isCategoryActionable(browser: .safari, category: .downloads))
        for browser in [Browser.chrome, .firefox, .brave, .arc, .opera, .edge] {
            XCTAssertFalse(
                vm.isCategoryActionable(browser: browser, category: .downloads),
                "Expected \(browser).downloads to be unactionable")
        }
    }

    // MARK: - Selection

    /// Toggling a `(browser, category)` selection must update both the
    /// checked state and the running total — the latter feeds the footer
    /// total label so a stale value would leave users confused about
    /// what's about to be cleared.
    func test_toggle_updatesIsCheckedAndTotalSelectedSize() async {
        // `pathsFor` returns a distinct stub URL per category so the
        // dedup logic in `totalSelectedSize` accounts for every cell —
        // cells with no paths contribute 0 by design (production sizers
        // also report 0 for those, since the clearer walks `pathsFor`).
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, category in category == .history ? 200 : 50 },
            pathsFor: { browser, category in
                [URL(fileURLWithPath: "/tmp/vctests/\(browser.rawValue)/\(category.rawValue)")]
            }
        )

        await vm.preview()
        // Default checked: history(200) + downloads(50) + cookies(50) + cache(50) + savedForms(50) = 400
        XCTAssertEqual(vm.totalSelectedSize, 400)

        vm.toggle(browser: .safari, category: .history)
        XCTAssertFalse(vm.isChecked(browser: .safari, category: .history))
        XCTAssertEqual(vm.totalSelectedSize, 200)

        vm.toggle(browser: .safari, category: .history)
        XCTAssertTrue(vm.isChecked(browser: .safari, category: .history))
        XCTAssertEqual(vm.totalSelectedSize, 400)
    }

    /// Two checked categories that point at the same on-disk path
    /// (Chromium `.history` and `.downloads` share the History SQLite)
    /// must contribute *one* size to `totalSelectedSize`, not two —
    /// otherwise the footer claims more bytes will be freed than the
    /// clearer can deliver.
    func test_totalSelectedSize_dedupesPathsSharedAcrossCategories() async {
        let sharedPath = URL(fileURLWithPath: "/tmp/vctests/Chrome/Default/History")
        let pathsForCategory: (Browser, PrivacyCategory) -> [URL] = { _, category in
            switch category {
            case .history, .downloads: return [sharedPath]
            case .cookies: return [URL(fileURLWithPath: "/tmp/vctests/Chrome/Default/Cookies")]
            default: return []
            }
        }
        let vm = makeViewModel(
            detected: [.chrome],
            sizer: { _, _ in 100 },
            pathsFor: pathsForCategory
        )

        await vm.preview()
        // Both .history and .downloads reference the same path, so the
        // shared-path size (100) is counted once. .cookies adds a unique
        // path (100). The remaining categories contribute 0 (no paths).
        XCTAssertEqual(vm.totalSelectedSize, 200)
    }

    // MARK: - Clear

    /// `clear()` must invoke the clearer for every checked
    /// `(browser, category)` pair — and only those — so an unchecked
    /// row's data is never silently removed.
    func test_clear_invokesClearerOnlyForCheckedSelections() async {
        let recorded = ActorBox<[String]>([])
        let vm = makeViewModel(
            detected: [.safari, .chrome],
            sizer: { _, _ in 50 },
            clearer: { browser, category in
                await recorded.append("\(browser.rawValue):\(category.rawValue)")
            }
        )
        await vm.preview()

        // Uncheck Chrome's cookies.
        vm.toggle(browser: .chrome, category: .cookies)

        await vm.clear()

        let received = await recorded.value
        XCTAssertFalse(received.contains("chrome:cookies"))
        XCTAssertTrue(received.contains("safari:history"))
        XCTAssertTrue(received.contains("chrome:history"))
    }

    /// `clear()` must invoke the recent-files manager exactly once when its
    /// toggle is on, and not at all when off.
    func test_clear_invokesRecentFilesManagerWhenToggleIsOn() async {
        let recentInvocations = ActorBox(0)
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 0 },
            clearer: { _, _ in },
            clearRecentFiles: { await recentInvocations.increment() }
        )

        await vm.preview()
        await vm.clear()

        let count = await recentInvocations.value
        XCTAssertEqual(count, 1)
    }

    func test_clear_doesNotInvokeRecentFilesManagerWhenToggleIsOff() async {
        let recentInvocations = ActorBox(0)
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 0 },
            clearer: { _, _ in },
            clearRecentFiles: { await recentInvocations.increment() }
        )

        await vm.preview()
        vm.toggleClearRecents()

        await vm.clear()

        let count = await recentInvocations.value
        XCTAssertEqual(count, 0)
    }

    /// On success, the phase must become `.complete(bytesFreed:)` so the
    /// view renders the "X freed" summary. Bytes freed comes from the
    /// pre-clear totals (the clearer doesn't return per-call sizes), so
    /// partial-failure cases would still report the optimistic total —
    /// acceptable since clearer errors are rare for user-domain paths.
    func test_clear_transitionsToCompleteWithBytesFreed() async {
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 100 },
            clearer: { _, _ in },
            pathsFor: { browser, category in
                [URL(fileURLWithPath: "/tmp/vctests/\(browser.rawValue)/\(category.rawValue)")]
            }
        )

        await vm.preview()
        let totalBefore = vm.totalSelectedSize
        XCTAssertEqual(totalBefore, 500, "Sanity check on captured pre-clear total")
        await vm.clear()

        XCTAssertEqual(vm.phase, .complete(bytesFreed: totalBefore))
    }

    /// `checkedSelections` is a `Set`; iterating it directly would yield
    /// nondeterministic order, so a mid-run failure would abort at a
    /// different point each run and make retries / bug reports
    /// inconsistent. The clear loop must iterate in
    /// `Browser.allCases × PrivacyCategory.allCases` order.
    func test_clear_invokesClearerInDeterministicBrowserCategoryOrder() async {
        let recorded = ActorBox<[String]>([])
        let vm = makeViewModel(
            detected: [.safari, .chrome, .firefox],
            sizer: { _, _ in 50 },
            clearer: { browser, category in
                await recorded.append("\(browser.rawValue):\(category.rawValue)")
            },
            clearRecentFiles: { }
        )

        await vm.preview()
        await vm.clear()

        let received = await recorded.value
        // Build the expected order from the same Browser × Category
        // enumeration the production VM uses, intersected with the
        // detected set.
        var expected: [String] = []
        for browser in [Browser.safari, .chrome, .firefox] {
            for category in PrivacyCategory.allCases {
                expected.append("\(browser.rawValue):\(category.rawValue)")
            }
        }
        XCTAssertEqual(received, expected,
                       "Clear must iterate in Browser × Category order")
    }

    /// Recents clearing runs *before* browser clearing — if recents
    /// throws, browser data must still be intact so the user can retry
    /// without hitting "browser shows 0 B because we already wiped it"
    /// confusion. We assert the browser clearer was never invoked when
    /// the recents step failed.
    func test_clear_clearsRecentsBeforeBrowsersAndAbortsOnRecentsFailure() async {
        struct BoomError: Error {}
        let browserClearerInvocations = ActorBox(0)
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 50 },
            clearer: { _, _ in await browserClearerInvocations.increment() },
            clearRecentFiles: { throw BoomError() }
        )

        await vm.preview()
        await vm.clear()

        let count = await browserClearerInvocations.value
        XCTAssertEqual(count, 0,
                       "Browser clearer must not run when the recents step throws")
        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    /// A throwing clearer must surface `.failed` — silent failures would
    /// claim "cleared" when the user's data is still on disk.
    func test_clear_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 100 },
            clearer: { _, _ in throw BoomError() }
        )

        await vm.preview()
        await vm.clear()

        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    /// Resetting while a clear is in progress must cancel the operation and
    /// leave the VM in a clean idle state, with any late task completion
    /// prevented from publishing `.complete`.
    func test_scanAgain_cancelsInFlightClearAndLeavesIdle() async {
        let firstClearStarted = expectation(description: "first clear started")
        var clearCalls = 0
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 50 },
            clearer: { _, _ in
                clearCalls += 1
                if clearCalls == 1 {
                    firstClearStarted.fulfill()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        )

        await vm.preview()
        let clearTask = Task { await vm.clear() }
        await fulfillment(of: [firstClearStarted], timeout: 1)

        vm.scanAgain()
        await clearTask.value

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Reset

    /// `scanAgain()` must drop the cached preview and selection so the
    /// next `preview()` starts from a clean slate.
    func test_scanAgain_returnsToIdle() async {
        let vm = makeViewModel(
            detected: [.safari],
            sizer: { _, _ in 100 },
            clearer: { _, _ in }
        )
        await vm.preview()
        await vm.clear()

        vm.scanAgain()

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Helpers

    private func makeViewModel(
        detected: [Browser] = [],
        detector: PrivacyViewModel.Detector? = nil,
        sizer: @escaping PrivacyViewModel.Sizer = { _, _ in 0 },
        clearer: @escaping PrivacyViewModel.Clearer = { _, _ in },
        pathsFor: @escaping PrivacyViewModel.PathsResolver = { _, _ in [] },
        clearRecentFiles: @escaping PrivacyViewModel.RecentFilesClearer = { }
    ) -> PrivacyViewModel {
        PrivacyViewModel(
            detector: detector ?? { detected },
            sizer: sizer,
            pathsFor: pathsFor,
            clearer: clearer,
            clearRecentFiles: clearRecentFiles
        )
    }
}

/// Small actor wrapper for race-free counters / collectors inside async
/// test closures. Mirrors the helper used in `SystemJunkViewModelTests`.
private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}

private extension ActorBox where Value == Int {
    func increment() { value += 1 }
}

private extension ActorBox where Value == [String] {
    func append(_ entry: String) { value.append(entry) }
}
