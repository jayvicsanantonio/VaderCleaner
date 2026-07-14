// ScanFileFilterTests.swift
// Pins ScanFileFilter: it returns exactly the matching files and runs the selection predicate off the main thread, so a Run/Clean tap over a huge result never hashes URLs on the main actor.

import XCTest
@testable import VaderCleaner

@MainActor
final class ScanFileFilterTests: XCTestCase {

    /// The filter keeps exactly the files the predicate matches, in order.
    func test_selected_keepsOnlyMatchingFiles() async {
        let a = file("/Users/me/Library/Caches/a")
        let b = file("/Users/me/Library/Caches/b")
        let c = file("/Users/me/Library/Caches/c")
        let wanted: Set<URL> = [a.url, c.url]

        let result = await ScanFileFilter.selected(from: [a, b, c]) { wanted.contains($0.url) }

        XCTAssertEqual(result, [a, c])
    }

    /// An empty predicate match yields no files rather than the whole input.
    func test_selected_ofNothing_isEmpty() async {
        let files = [file("/a"), file("/b")]
        let result = await ScanFileFilter.selected(from: files) { _ in false }
        XCTAssertTrue(result.isEmpty)
    }

    /// The predicate runs off the main thread. Hashing a million bridged URLs
    /// on the main actor is exactly the freeze this helper exists to avoid, so
    /// the filter must never run on the main thread.
    func test_selected_runsThePredicateOffTheMainThread() async {
        let sawMainThread = SendableBox<Bool?>(nil)
        let files = [file("/a"), file("/b")]

        _ = await ScanFileFilter.selected(from: files) { file in
            sawMainThread.value = Thread.isMainThread
            return true
        }

        XCTAssertEqual(
            sawMainThread.value,
            false,
            "The selection filter must run off the main thread so a huge result can't freeze the Run/Clean tap"
        )
    }

    // MARK: - Helpers

    private func file(_ path: String) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: 1,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
    }
}

/// Mutable reference cell capturable by the `@Sendable` predicate. The
/// unchecked conformance is safe here: the test awaits the filter before
/// reading, so the write strictly precedes the read.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
