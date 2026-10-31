// MaintenanceTaskTests.swift
// Verifies the maintenance-task catalog is complete, uniquely identified, and fully described.

import XCTest
@testable import VaderCleanerCore

final class MaintenanceTaskTests: XCTestCase {

    func test_catalog_containsEveryTaskKindExactlyOnce() {
        let kinds = MaintenanceTask.catalog.map(\.kind)
        XCTAssertEqual(Set(kinds).count, kinds.count, "Catalog must not repeat a task kind")
        XCTAssertEqual(Set(kinds), Set(MaintenanceTask.Kind.allCases))
    }

    func test_catalog_everyTaskIsFullyDescribed() {
        for task in MaintenanceTask.catalog {
            XCTAssertFalse(task.title.isEmpty, "\(task.kind) needs a title")
            XCTAssertFalse(task.summary.isEmpty, "\(task.kind) needs a summary")
            XCTAssertFalse(task.icon.isEmpty, "\(task.kind) needs an icon")
        }
    }

    func test_catalog_idsAreUnique() {
        let ids = MaintenanceTask.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func test_speedUpMail_isTheOnlyUserLevelTask() {
        let userLevel = MaintenanceTask.catalog.filter { !$0.requiresHelper }.map(\.kind)
        XCTAssertEqual(userLevel, [.speedUpMail])
    }

    func test_maintenanceCocktail_holdsOnlyRoutineUpkeep() {
        // Freeing RAM, thinning snapshots, and erasing the Spotlight index are
        // run when something calls for them, never on a weekly nudge.
        XCTAssertEqual(
            Set(MaintenanceTask.maintenanceCocktailKinds),
            [.runMaintenanceScripts, .flushDNS, .speedUpMail]
        )
    }
}
