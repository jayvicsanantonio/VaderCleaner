// SmartScanViewModelMaintenanceReceiptTests.swift
// Tests the failure copy on the Run receipt's tune-up line: an unreachable helper reads as VaderCleaner's own message, and any other failure keeps its own text.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelMaintenanceReceiptTests: XCTestCase {

    /// Two due tasks, both of which the injected runner fails, so the receipt
    /// line lands on `.failed` and carries a message.
    private nonisolated static var maintenancePlan: CarePlan {
        CarePlan(
            findings: [
                CareFinding(payload: .maintenanceDue(taskIDs: ["flushDNS", "reindexSpotlight"]))
            ],
            health: nil,
            unitOutcomes: [.maintenanceDue: .completed],
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    private static func viewModel(
        maintenanceTaskRunner: @escaping SmartScanViewModel.MaintenanceTaskRunner
    ) -> SmartScanViewModel {
        SmartScanViewModel(
            scanEngine: { _, _ in Self.maintenancePlan },
            maintenanceTaskRunner: maintenanceTaskRunner
        )
    }

    private func receiptLine(_ vm: SmartScanViewModel) -> CareReceiptLine? {
        guard case .done(let receipt) = vm.phase else { return nil }
        return receipt.lines.first { $0.kind == .maintenanceDue }
    }

    /// Every tune-up task runs through the privileged helper, and a dead
    /// connection arrives as an `NSXPCConnection` Cocoa error whose system text
    /// is the cryptic "Couldn't communicate with a helper application." The
    /// receipt must carry VaderCleaner's own copy instead — the same mapping
    /// every other helper-backed screen applies.
    func test_run_maintenance_helperConnectionFailure_reportsTheAppsOwnCopy() async {
        let vm = Self.viewModel(maintenanceTaskRunner: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: 4099)
        })

        await vm.scan()
        await vm.run()

        XCTAssertEqual(receiptLine(vm)?.outcome, .failed(message: HelperConnectionError.message))
    }

    /// Only connection-class failures collapse to that copy — a task that failed
    /// for its own reasons still says what actually went wrong.
    func test_run_maintenance_otherFailure_keepsTheErrorsOwnText() async {
        let vm = Self.viewModel(maintenanceTaskRunner: { _ in
            throw NSError(
                domain: "t",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Close Mail first, then try again."]
            )
        })

        await vm.scan()
        await vm.run()

        XCTAssertEqual(receiptLine(vm)?.outcome, .failed(message: "Close Mail first, then try again."))
    }
}
