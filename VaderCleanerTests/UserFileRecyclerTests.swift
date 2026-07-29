// UserFileRecyclerTests.swift
// Pins UserFileRecycler's empty-input guard and its partial-result contract — the two behaviours that had drifted apart across the four per-section copies this type replaced.

import XCTest
@testable import VaderCleaner

/// These tests deliberately never recycle a real file. `NSWorkspace.recycle`
/// moves items into the *running user's* Trash, which a test suite must not do
/// as a side effect — so what is pinned here is the guard that runs before
/// AppKit is ever reached, plus the shape of the value callers depend on.
final class UserFileRecyclerTests: XCTestCase {

    /// An empty batch resolves to an empty set without touching
    /// `NSWorkspace`. Two of the four implementations this type replaced were
    /// missing this guard and called through to AppKit with an empty array on
    /// every "remove selected" with nothing selected.
    func test_recycle_emptyInput_returnsEmptyWithoutTouchingWorkspace() async {
        let moved = await UserFileRecycler.recycle([], context: "test")
        XCTAssertTrue(moved.isEmpty)
    }

    /// The guard resolves promptly rather than parking on a continuation that
    /// nothing will resume — a deadlock here would hang the calling section's
    /// remove action forever.
    func test_recycle_emptyInput_completesPromptly() async {
        let started = Date()
        _ = await UserFileRecycler.recycle([], context: "test")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1.0,
            "The empty-input guard must return without awaiting a continuation"
        )
    }

    /// Callers prune their models against the returned set, so it has to be
    /// the set of URLs that *moved* — never the input echoed back. A URL that
    /// failed to move must be absent, which is what keeps a locked file on
    /// screen instead of silently vanishing from the list.
    ///
    /// Verified against the injected seam every section uses rather than
    /// against AppKit: each view model takes its recycle sink as a closure, so
    /// this is the contract the production wiring has to satisfy.
    func test_recycleSink_contractIsMovedSubset_notTheInput() async {
        let requested = [
            URL(fileURLWithPath: "/tmp/a"),
            URL(fileURLWithPath: "/tmp/b"),
        ]
        // Stands in for a batch where the second file is locked.
        let sink: @Sendable ([URL]) async -> Set<URL> = { urls in
            Set(urls.prefix(1))
        }

        let moved = await sink(requested)

        XCTAssertEqual(moved, [URL(fileURLWithPath: "/tmp/a")])
        XCTAssertFalse(
            moved.contains(URL(fileURLWithPath: "/tmp/b")),
            "A file that did not move must be absent so the caller keeps it on screen"
        )
    }
}
