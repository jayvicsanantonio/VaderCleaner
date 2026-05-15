// ExtensionsManagerViewModelTests.swift
// Drives the ExtensionsManagerViewModel state machine — load, type grouping, removal, and failure paths — through injected fakes so no real extension state is touched.

import XCTest
@testable import VaderCleaner

@MainActor
final class ExtensionsManagerViewModelTests: XCTestCase {

    // MARK: - Initial state

    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.groupedByType.isEmpty)
    }

    // MARK: - Refresh

    /// `refresh()` populates `items` and lands `.ready`.
    func test_refresh_populatesItemsAndBecomesReady() async {
        let vm = makeViewModel(discover: {
            [Self.item(name: "A", type: .safariExtension)]
        })
        await vm.refresh()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.items.map(\.name), ["A"])
    }

    /// A throwing discovery surfaces `.failed(stage: .loading, ...)`.
    func test_refresh_failureTransitionsToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(discover: { throw Boom() })
        await vm.refresh()
        if case .failed(let stage, _) = vm.phase {
            XCTAssertEqual(stage, .loading)
        } else {
            XCTFail("Expected .failed(.loading), got \(vm.phase)")
        }
        XCTAssertTrue(vm.items.isEmpty)
    }

    // MARK: - Grouping

    /// `groupedByType` buckets items by `ExtensionType` and emits the
    /// groups in `ExtensionType.allCases` declaration order, skipping
    /// empty buckets.
    func test_groupedByType_bucketsInAllCasesOrder() async {
        let vm = makeViewModel(discover: {
            [
                Self.item(name: "Login", type: .loginItemFromApp),
                Self.item(name: "Safari1", type: .safariExtension),
                Self.item(name: "Mail1", type: .mailPlugin),
                Self.item(name: "Safari2", type: .safariExtension)
            ]
        })
        await vm.refresh()

        let grouped = vm.groupedByType
        XCTAssertEqual(grouped.map(\.0),
                       [.safariExtension, .mailPlugin, .loginItemFromApp])
        XCTAssertEqual(grouped.first?.1.map(\.name), ["Safari1", "Safari2"])
    }

    /// Empty discovery → `.ready` with no groups (drives the empty state).
    func test_groupedByType_emptyWhenNoItems() async {
        let vm = makeViewModel(discover: { [] })
        await vm.refresh()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.groupedByType.isEmpty)
    }

    // MARK: - Removal

    /// A successful removal drops the row, re-groups, and lands `.ready`.
    func test_remove_dropsItemAndReturnsToReady() async {
        let target = Self.item(name: "Doomed", type: .mailPlugin)
        let keep = Self.item(name: "Keeper", type: .safariExtension)
        let vm = makeViewModel(
            discover: { [target, keep] },
            remove: { _ in }
        )
        await vm.refresh()
        await vm.remove(target)

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.items.map(\.name), ["Keeper"])
        XCTAssertEqual(vm.groupedByType.map(\.0), [.safariExtension])
    }

    /// The removed item is the one passed to the injected remover.
    func test_remove_forwardsTheSelectedItemToRemover() async {
        let target = Self.item(name: "Doomed", type: .internetPlugin)
        var removed: ExtensionItem?
        let vm = makeViewModel(
            discover: { [target] },
            remove: { removed = $0 }
        )
        await vm.refresh()
        await vm.remove(target)
        XCTAssertEqual(removed, target)
    }

    /// A throwing remover surfaces `.failed(stage: .removing, ...)` and
    /// leaves the item list intact so the user can retry.
    func test_remove_failureTransitionsToFailedRemoving() async {
        struct Boom: Error {}
        let target = Self.item(name: "Doomed", type: .mailPlugin)
        let vm = makeViewModel(
            discover: { [target] },
            remove: { _ in throw Boom() }
        )
        await vm.refresh()
        await vm.remove(target)

        if case .failed(let stage, _) = vm.phase {
            XCTAssertEqual(stage, .removing)
        } else {
            XCTFail("Expected .failed(.removing), got \(vm.phase)")
        }
        XCTAssertEqual(vm.items.map(\.name), ["Doomed"])
    }

    /// `dismissResult()` returns a failed VM to `.ready` so the user can
    /// retry without re-running discovery.
    func test_dismissResult_returnsToReady() async {
        struct Boom: Error {}
        let target = Self.item(name: "Doomed", type: .mailPlugin)
        let vm = makeViewModel(
            discover: { [target] },
            remove: { _ in throw Boom() }
        )
        await vm.refresh()
        await vm.remove(target)
        vm.dismissResult()
        XCTAssertEqual(vm.phase, .ready)
    }

    // MARK: - Helpers

    private func makeViewModel(
        discover: @escaping ExtensionsManagerViewModel.Discover = { [] },
        remove: @escaping ExtensionsManagerViewModel.Remove = { _ in }
    ) -> ExtensionsManagerViewModel {
        ExtensionsManagerViewModel(discover: discover, remove: remove)
    }

    private static func item(
        name: String,
        type: ExtensionType
    ) -> ExtensionItem {
        ExtensionItem(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(name)"),
            bundleID: nil,
            type: type,
            isEnabled: true,
            size: 0
        )
    }
}
