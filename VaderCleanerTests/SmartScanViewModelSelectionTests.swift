// SmartScanViewModelSelectionTests.swift
// Tests the per-finding selection APIs: batched junk toggles with O(1) tallies, threat/update/duplicate selection, opt-in setters that sync their card's inclusion, and the informational guard.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelSelectionTests: XCTestCase {

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

    private nonisolated var junkFiles: [ScannedFile] {
        [
            file("/caches/a", size: 100, category: .userCache),
            file("/caches/b", size: 200, category: .userCache),
            file("/logs/c", size: 50, category: .userLogs),
            file("/mail/d", size: 500, category: .mailAttachments)
        ]
    }

    private nonisolated var fixturePlan: CarePlan {
        let threats = [
            MalwareThreat(filePath: URL(fileURLWithPath: "/t1"), threatName: "A"),
            MalwareThreat(filePath: URL(fileURLWithPath: "/t2"), threatName: "B")
        ]
        let updates = [
            UpdateInfo(
                appName: "One", bundleID: "com.example.one",
                bundleURL: URL(fileURLWithPath: "/Applications/One.app"),
                installedVersion: "1", latestVersion: "2",
                source: .appStore, updateURL: URL(string: "https://example.com")!
            )
        ]
        let group = DuplicateGroup(files: [
            file("/d/original", size: 10),
            file("/d/copy1", size: 10),
            file("/d/copy2", size: 10)
        ])
        return CarePlan(
            findings: [
                CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: junkFiles))),
                CareFinding(kind: .threats, payload: .threats(threats)),
                CareFinding(kind: .appUpdates, payload: .appUpdates(updates)),
                CareFinding(kind: .duplicates, payload: .duplicates([group])),
                CareFinding(kind: .loginItems, payload: .loginItems([
                    LoginItem(id: "x", name: "Agent", isEnabled: true)
                ]))
            ],
            health: nil,
            unitOutcomes: [
                .systemJunk: .completed, .malware: .completed,
                .appUpdates: .completed, .duplicates: .completed, .loginItems: .completed
            ],
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    private func makeVM() async -> SmartScanViewModel {
        let plan = fixturePlan
        let vm = SmartScanViewModel(scanEngine: { _, _ in plan })
        await vm.scan()
        return vm
    }

    // MARK: - Junk selection & tallies

    func test_junkToggles_keepTalliesInLockstep() async {
        let vm = await makeVM()
        // Seeded: safe categories only (userCache 300 + userLogs 50).
        XCTAssertEqual(vm.selectedJunkBytes, 350)
        XCTAssertEqual(vm.selectedJunkBytes(in: .userCache), 300)
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 2)

        vm.toggleJunkFile(file("/caches/a", size: 100, category: .userCache))
        XCTAssertEqual(vm.selectedJunkBytes, 250)
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 1)

        vm.toggleJunkFiles([
            file("/caches/a", size: 100, category: .userCache),
            file("/caches/b", size: 200, category: .userCache)
        ])
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 2, "a partial group toggles to fully selected")
        XCTAssertEqual(vm.selectedJunkBytes, 350)
    }

    func test_junkCategory_bulkSetAndDerivedSelection() async {
        let vm = await makeVM()
        XCTAssertFalse(vm.isJunkCategorySelected(.mailAttachments), "user data seeds unchecked")
        vm.setJunkCategory(.mailAttachments, selected: true)
        XCTAssertTrue(vm.isJunkCategorySelected(.mailAttachments))
        XCTAssertEqual(vm.selectedJunkBytes, 850)
        vm.toggleJunkCategory(.mailAttachments)
        XCTAssertFalse(vm.isJunkCategorySelected(.mailAttachments))
        XCTAssertEqual(vm.selectedJunkBytes, 350)
    }

    // MARK: - Threats & updates

    func test_threatSelection_toggleAndBulk() async {
        let vm = await makeVM()
        let threat = MalwareThreat(filePath: URL(fileURLWithPath: "/t1"), threatName: "A")
        XCTAssertTrue(vm.isThreatSelected(threat), "threats seed fully selected")
        vm.toggleThreat(threat)
        XCTAssertFalse(vm.isThreatSelected(threat))
        vm.setAllThreats(selected: true)
        XCTAssertEqual(vm.threatSelection.count, 2)
        vm.setAllThreats(selected: false)
        XCTAssertTrue(vm.threatSelection.isEmpty)
    }

    func test_updateSelection_toggleAndBulk() async {
        let vm = await makeVM()
        let update = UpdateInfo(
            appName: "One", bundleID: "com.example.one",
            bundleURL: URL(fileURLWithPath: "/Applications/One.app"),
            installedVersion: "1", latestVersion: "2",
            source: .appStore, updateURL: URL(string: "https://example.com")!
        )
        XCTAssertTrue(vm.isUpdateSelected(update))
        vm.toggleUpdate(update)
        XCTAssertFalse(vm.isUpdateSelected(update))
        vm.setAllUpdates(selected: true)
        XCTAssertTrue(vm.isUpdateSelected(update))
    }

    // MARK: - Duplicates

    func test_duplicateSelection_neverIncludesTheKeptOriginal() async {
        let vm = await makeVM()
        XCTAssertEqual(
            vm.duplicateSelection,
            [URL(fileURLWithPath: "/d/copy1"), URL(fileURLWithPath: "/d/copy2")]
        )
        vm.clearDuplicateSelection()
        XCTAssertTrue(vm.duplicateSelection.isEmpty)
        vm.selectAllDuplicates()
        XCTAssertFalse(vm.duplicateSelection.contains(URL(fileURLWithPath: "/d/original")))
        vm.setDuplicates([URL(fileURLWithPath: "/d/copy1")], selected: false)
        XCTAssertEqual(vm.duplicateSelection, [URL(fileURLWithPath: "/d/copy2")])
    }

    // MARK: - Inclusion

    func test_setFindingIncluded_refusesInformationalKinds() async {
        let vm = await makeVM()
        vm.setFindingIncluded(.loginItems, true)
        XCTAssertFalse(vm.isFindingIncluded(.loginItems), "informational findings can never join Run")
    }

    func test_selectionCount_reflectsEachTier() async {
        let vm = await makeVM()
        XCTAssertEqual(vm.selectionCount(for: .junkCleanup), 3)
        XCTAssertEqual(vm.selectionCount(for: .threats), 2)
        XCTAssertEqual(vm.selectionCount(for: .duplicates), 2)
        XCTAssertEqual(vm.selectionCount(for: .largeOldFiles), 0)
    }

    // MARK: - Opt-in setters sync their card

    func test_unusedAppAndLeftoverAndInstallerSetters_syncInclusion() async {
        let vm = await makeVM()
        // The fixture has no findings for these kinds, but the selection
        // machinery is kind-independent; setFindingIncluded guards on the
        // plan, while the sync path only mirrors selection state.
        vm.setUnusedApps(["a"], selected: true)
        XCTAssertTrue(vm.includedFindings.contains(.unusedApps))
        vm.setUnusedApps(["a"], selected: false)
        XCTAssertFalse(vm.includedFindings.contains(.unusedApps))

        vm.setLeftovers(["com.gone.app"], selected: true)
        XCTAssertTrue(vm.includedFindings.contains(.appLeftovers))
        vm.setInstallers(["/Downloads/x.dmg"], selected: true)
        XCTAssertTrue(vm.includedFindings.contains(.installers))
    }
}
