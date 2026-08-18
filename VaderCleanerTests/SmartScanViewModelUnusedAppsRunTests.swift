// SmartScanViewModelUnusedAppsRunTests.swift
// Tests that uninstalling an unused app through Smart Scan performs the Applications Manager's full sweep — bundle plus associated files — and reports apps, not files, on the receipt.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelUnusedAppsRunTests: XCTestCase {

    // MARK: - Fixtures

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func record(_ entry: String) { lock.lock(); defer { lock.unlock() }; storage.append(entry) }
        var entries: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private nonisolated func unusedApp(_ name: String, sizeBytes: Int64 = 1_000) -> UnusedApp {
        UnusedApp(
            app: AppInfo(
                name: name,
                bundleID: "com.example.\(name.lowercased())",
                version: "1.0",
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                isAppStore: false
            ),
            lastUsedDate: .distantPast,
            sizeBytes: sizeBytes
        )
    }

    private nonisolated func plan(_ apps: [UnusedApp]) -> CarePlan {
        CarePlan(
            findings: [CareFinding(payload: .unusedApps(apps))],
            health: nil,
            unitOutcomes: [.unusedApps: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    // MARK: - The full sweep

    /// Removing an unused app takes its support files with it, the same
    /// sweep the Uninstaller performs. Recycling the bundle alone leaves
    /// preferences, caches, and containers on disk — which the very next
    /// scan reports back as leftovers.
    func test_run_unusedApps_recycleTheirAssociatedFilesToo() async {
        let recorder = Recorder()
        let stale = unusedApp("Stale")
        let fixture = plan([stale])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in fixture },
            recycleFiles: { urls in
                for u in urls { recorder.record("recycle:\(u.path)") }
                return Set(urls)
            },
            findAssociatedFiles: { bundleID in
                guard bundleID == "com.example.stale" else { return [] }
                return [
                    AssociatedFile(
                        url: URL(fileURLWithPath: "/Library/Preferences/com.example.stale.plist"),
                        sizeBytes: 20,
                        category: .preferences
                    ),
                    AssociatedFile(
                        url: URL(fileURLWithPath: "/Library/Caches/com.example.stale"),
                        sizeBytes: 300,
                        category: .cache
                    )
                ]
            }
        )
        await vm.scan()
        vm.setUnusedApps([stale.id], selected: true)
        await vm.run()

        let entries = Set(recorder.entries)
        XCTAssertTrue(entries.contains("recycle:/Applications/Stale.app"))
        XCTAssertTrue(entries.contains("recycle:/Library/Preferences/com.example.stale.plist"))
        XCTAssertTrue(entries.contains("recycle:/Library/Caches/com.example.stale"))

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        let line = receipt.lines.first { $0.kind == .unusedApps }
        XCTAssertEqual(line?.itemsProcessed, 1, "the receipt counts apps removed, not files touched")
        XCTAssertEqual(line?.bytesFreed, 1_000 + 20 + 300, "support files count toward the space reclaimed")
        XCTAssertEqual(line?.outcome, .success)
    }

    /// Only chosen apps are swept: an app left unchecked has neither its
    /// bundle nor its support files looked up.
    func test_run_unusedApps_leaveUncheckedAppsEntirelyAlone() async {
        let recorder = Recorder()
        let stale = unusedApp("Stale")
        let kept = unusedApp("Kept")
        let fixture = plan([stale, kept])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in fixture },
            recycleFiles: { urls in
                for u in urls { recorder.record("recycle:\(u.path)") }
                return Set(urls)
            },
            findAssociatedFiles: { bundleID in
                recorder.record("lookup:\(bundleID)")
                return []
            }
        )
        await vm.scan()
        vm.setUnusedApps([stale.id], selected: true)
        await vm.run()

        let entries = Set(recorder.entries)
        XCTAssertTrue(entries.contains("recycle:/Applications/Stale.app"))
        XCTAssertTrue(entries.contains("lookup:com.example.stale"))
        XCTAssertFalse(entries.contains("recycle:/Applications/Kept.app"))
        XCTAssertFalse(entries.contains("lookup:com.example.kept"), "an unchecked app is never even inspected")
    }

    /// An app whose bundle would not move is not uninstalled, however many
    /// of its support files went to the Trash.
    func test_run_unusedApps_bundleThatFailsToRecycleReportsPartial() async {
        let stuck = unusedApp("Stuck")
        let prefs = URL(fileURLWithPath: "/Library/Preferences/com.example.stuck.plist")
        let fixture = plan([stuck])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in fixture },
            // The bundle is locked; only the preference file moves.
            recycleFiles: { urls in Set(urls.filter { $0 == prefs }) },
            findAssociatedFiles: { _ in
                [AssociatedFile(url: prefs, sizeBytes: 20, category: .preferences)]
            }
        )
        await vm.scan()
        vm.setUnusedApps([stuck.id], selected: true)
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        let line = receipt.lines.first { $0.kind == .unusedApps }
        XCTAssertEqual(line?.itemsProcessed, 0)
        XCTAssertEqual(line?.outcome, .partial(failedCount: 1))
    }
}
