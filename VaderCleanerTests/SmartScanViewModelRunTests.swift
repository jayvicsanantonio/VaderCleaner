// SmartScanViewModelRunTests.swift
// Tests the Run pass: the zero-interaction safety invariant, per-finding failure isolation, Trash-based routing, receipt math, and the browser-running refusal path.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelRunTests: XCTestCase {

    // MARK: - Fixtures

    private nonisolated func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private nonisolated var richPlan: CarePlan {
        let junk = ScanResult(items: [
            file("/cache/safe", size: 1_000, category: .userCache),
            file("/mail/attachment", size: 500, category: .mailAttachments)
        ])
        let threats = [
            MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar"),
            MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil2"), threatName: "Eicar")
        ]
        let dupGroup = DuplicateGroup(files: [
            file("/Downloads/original", size: 10),
            file("/Downloads/copy", size: 10)
        ])
        let bigFile = file("/Movies/huge.mov", size: 9_000, category: .largeFile)
        return CarePlan(
            findings: [
                CareFinding(kind: .junkCleanup, payload: .junk(junk)),
                CareFinding(kind: .threats, payload: .threats(threats)),
                CareFinding(kind: .duplicates, payload: .duplicates([dupGroup])),
                CareFinding(kind: .largeOldFiles, payload: .largeOldFiles([bigFile])),
                CareFinding(kind: .maintenanceDue, payload: .maintenanceDue(taskIDs: ["flushDNS", "speedUpMail"])),
            ],
            health: nil,
            unitOutcomes: [
                .systemJunk: .completed, .malware: .completed, .duplicates: .completed,
                .largeOldFiles: .completed, .maintenanceDue: .completed
            ],
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func record(_ entry: String) { lock.lock(); defer { lock.unlock() }; storage.append(entry) }
        var entries: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    // MARK: - The safety invariant

    func test_run_withZeroInteraction_touchesOnlyPreApprovedWork() async {
        let recorder = Recorder()
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            junkCleaner: { files in
                for f in files { recorder.record("junk:\(f.url.path)") }
                return files.reduce(0) { $0 + $1.size }
            },
            threatRemover: { threats in
                for t in threats { recorder.record("threat:\(t.filePath.path)") }
                return []
            },
            recycleFiles: { urls in
                for u in urls { recorder.record("recycle:\(u.path)") }
                return Set(urls)
            },
            maintenanceTaskRunner: { recorder.record("task:\($0)") }
        )
        await vm.scan()
        await vm.run()

        let entries = Set(recorder.entries)
        XCTAssertTrue(entries.contains("junk:/cache/safe"), "safe junk runs")
        XCTAssertFalse(entries.contains("junk:/mail/attachment"), "user-data junk category must not run unchecked")
        XCTAssertTrue(entries.contains("recycle:/Downloads/copy"), "redundant duplicate copies run")
        XCTAssertFalse(entries.contains("recycle:/Downloads/original"), "the kept original is never touched")
        XCTAssertFalse(entries.contains("recycle:/Movies/huge.mov"), "opt-in large files must not run without an explicit choice")
        XCTAssertTrue(entries.contains("threat:/tmp/evil"))
        XCTAssertTrue(entries.contains("task:flushDNS"))
    }

    func test_run_similarImagesAndDownloads_recycleOnlyChosen() async {
        let recorder = Recorder()
        let simGroup = SimilarImageGroup(files: [
            file("/Pictures/best.jpg", size: 100, category: .largeFile),
            file("/Pictures/near.jpg", size: 90, category: .largeFile),
        ])
        let download = DownloadItem(
            file: file("/Downloads/old.dmg", size: 500, category: .largeFile),
            sourceApp: "Safari"
        )
        let plan = CarePlan(
            findings: [
                CareFinding(kind: .similarImages, payload: .similarImages([simGroup])),
                CareFinding(kind: .downloads, payload: .downloads([download])),
            ],
            health: nil,
            unitOutcomes: [.similarImages: .completed, .downloads: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in plan },
            recycleFiles: { urls in
                for u in urls { recorder.record("recycle:\(u.path)") }
                return Set(urls)
            }
        )
        await vm.scan()

        // Both are opt-in, so they seed empty — nothing is selected until chosen.
        XCTAssertEqual(vm.selectionCount(for: .similarImages), 0)
        XCTAssertEqual(vm.selectionCount(for: .downloads), 0)

        // Choose one near-duplicate and the download, then run once.
        vm.setSimilarImages([URL(fileURLWithPath: "/Pictures/near.jpg")], selected: true)
        vm.setDownloads([URL(fileURLWithPath: "/Downloads/old.dmg")], selected: true)
        await vm.run()

        let entries = Set(recorder.entries)
        XCTAssertTrue(entries.contains("recycle:/Pictures/near.jpg"), "the chosen near-duplicate runs")
        XCTAssertFalse(entries.contains("recycle:/Pictures/best.jpg"), "the kept best shot is never touched")
        XCTAssertTrue(entries.contains("recycle:/Downloads/old.dmg"), "the chosen download runs")
    }

    // MARK: - Receipt math

    func test_run_buildsReceipt_withBytesAndOrder() async {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            junkCleaner: { files in files.reduce(0) { $0 + $1.size } },
            threatRemover: { _ in [] },
            recycleFiles: { Set($0) },
            maintenanceTaskRunner: { _ in }
        )
        await vm.scan()
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(
            receipt.lines.map(\.kind),
            [.threats, .junkCleanup, .duplicates, .maintenanceDue],
            "receipt lines follow feed order; unexecuted findings have no line"
        )
        XCTAssertEqual(receipt.totalBytesFreed, 1_000 + 10)
        let junkLine = receipt.lines.first { $0.kind == .junkCleanup }
        XCTAssertEqual(junkLine?.itemsProcessed, 1)
        XCTAssertEqual(junkLine?.bytesFreed, 1_000)
        XCTAssertEqual(junkLine?.outcome, .success)
    }

    // MARK: - Failure isolation

    func test_run_oneFailingFinding_leavesTheRestIntact() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "no permission" } }
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            junkCleaner: { _ in throw Boom() },
            threatRemover: { _ in [] },
            recycleFiles: { Set($0) },
            maintenanceTaskRunner: { _ in }
        )
        await vm.scan()
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(
            receipt.lines.first { $0.kind == .junkCleanup }?.outcome,
            .failed(message: "no permission")
        )
        XCTAssertEqual(receipt.lines.first { $0.kind == .threats }?.outcome, .success)
        XCTAssertEqual(receipt.lines.first { $0.kind == .duplicates }?.outcome, .success)
    }

    func test_run_threatRemoverFailures_reportPartial() async {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            threatRemover: { threats in [threats[0]] },
            recycleFiles: { Set($0) },
            maintenanceTaskRunner: { _ in }
        )
        await vm.scan()
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        let line = receipt.lines.first { $0.kind == .threats }
        XCTAssertEqual(line?.outcome, .partial(failedCount: 1))
        XCTAssertEqual(line?.itemsProcessed, 1)
    }

    func test_run_recyclePartial_reportsShortfall() async {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            threatRemover: { _ in [] },
            recycleFiles: { _ in [] },
            maintenanceTaskRunner: { _ in }
        )
        await vm.scan()
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        guard case .failed = receipt.lines.first(where: { $0.kind == .duplicates })?.outcome else {
            return XCTFail("a recycle batch that moved nothing must read as failed")
        }
    }

    // MARK: - Inclusion gating

    func test_run_skipsCardsTheUserExcluded() async {
        let junkCalls = Recorder()
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            junkCleaner: { files in junkCalls.record("called"); return files.reduce(0) { $0 + $1.size } },
            threatRemover: { _ in [] },
            recycleFiles: { Set($0) },
            maintenanceTaskRunner: { _ in }
        )
        await vm.scan()
        vm.setFindingIncluded(.junkCleanup, false)
        await vm.run()
        XCTAssertTrue(junkCalls.entries.isEmpty, "an excluded card's work must not run")
    }

    // MARK: - Maintenance

    func test_run_maintenance_recordsEachCompletedTask() async {
        let recorded = Recorder()
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            threatRemover: { _ in [] },
            recycleFiles: { Set($0) },
            maintenanceTaskRunner: { id in
                if id == "speedUpMail" { throw NSError(domain: "t", code: 1) }
            },
            recordMaintenanceRun: { recorded.record($0) }
        )
        await vm.scan()
        await vm.run()

        XCTAssertEqual(recorded.entries, ["flushDNS"], "only completed tasks stamp the run log")
        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(
            receipt.lines.first { $0.kind == .maintenanceDue }?.outcome,
            .partial(failedCount: 1)
        )
    }

    // MARK: - History hooks

    func test_scanAndRun_stampTheHistoryHooks() async {
        let recorded = Recorder()
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in self.richPlan },
            junkCleaner: { files in files.reduce(0) { $0 + $1.size } },
            threatRemover: { _ in [] },
            recycleFiles: { Set($0) },
            maintenanceTaskRunner: { _ in },
            recordScan: { _ in recorded.record("scan") },
            recordReceipt: { receipt in recorded.record("receipt:\(receipt.totalBytesFreed)") }
        )
        await vm.scan()
        XCTAssertEqual(recorded.entries, ["scan"], "landing results stamps the scan date")
        await vm.run()
        XCTAssertEqual(
            recorded.entries,
            ["scan", "receipt:\(1_000 + 10)"],
            "completing a Run pass records its receipt"
        )
    }

    // MARK: - Browser privacy refusal

    func test_run_browserRunning_surfacesPlainReceiptLine() async {
        let plan = CarePlan(
            findings: [
                CareFinding(kind: .browserPrivacy, payload: .browserPrivacy([
                    BrowserPrivacySummary(browser: .safari, counts: [.cookies: 12])
                ]))
            ],
            health: nil,
            unitOutcomes: [.browserPrivacy: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in plan },
            privacyRemover: { _ in throw PrivacyRemovalError.browserRunning(.safari) }
        )
        await vm.scan()
        vm.toggleBrowserPrivacy(BrowserPrivacyKey(browser: .safari, category: .cookies))
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            return XCTFail("expected .done, got \(vm.phase)")
        }
        guard case .failed(let message)? = receipt.lines.first(where: { $0.kind == .browserPrivacy })?.outcome else {
            return XCTFail("expected a failed browser-privacy line")
        }
        XCTAssertTrue(message.contains("Safari"), "the message names the browser to close: \(message)")
    }

    func test_toggleBrowserPrivacy_refusesInformationalCategories() async {
        let plan = CarePlan(
            findings: [
                CareFinding(kind: .browserPrivacy, payload: .browserPrivacy([
                    BrowserPrivacySummary(browser: .safari, counts: [.savedPasswords: 3])
                ]))
            ],
            health: nil,
            unitOutcomes: [.browserPrivacy: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
        let vm = SmartScanViewModel(scanEngine: { _, _ in plan })
        await vm.scan()
        vm.toggleBrowserPrivacy(BrowserPrivacyKey(browser: .safari, category: .savedPasswords))
        XCTAssertTrue(vm.browserPrivacySelection.isEmpty, "passwords are informational and can never be selected")
    }
}
