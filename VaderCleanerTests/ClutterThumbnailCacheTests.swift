// ClutterThumbnailCacheTests.swift
// Verifies the process-wide Quick Look thumbnail cache round-trips images and keys distinctly by path and point size.

import XCTest
import AppKit
@testable import VaderCleaner

final class ClutterThumbnailCacheTests: XCTestCase {

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4))
    }

    func test_store_thenCached_returnsTheSameImage() {
        let url = URL(fileURLWithPath: "/tmp/clutter-thumb-tests/\(UUID().uuidString).mov")
        let image = makeImage()

        XCTAssertNil(ClutterThumbnailCache.cached(url, pointSize: 92), "Unseeded key misses")

        ClutterThumbnailCache.store(image, for: url, pointSize: 92)

        XCTAssertTrue(ClutterThumbnailCache.cached(url, pointSize: 92) === image,
                      "A stored thumbnail is returned on the next lookup")
    }

    /// The same file requested at different point sizes (card corner vs. manager
    /// preview) must not collide — each size gets its own entry.
    func test_cache_keysDistinctlyByPointSize() {
        let url = URL(fileURLWithPath: "/tmp/clutter-thumb-tests/\(UUID().uuidString).jpg")
        let small = makeImage()
        let large = makeImage()

        ClutterThumbnailCache.store(small, for: url, pointSize: 46)
        ClutterThumbnailCache.store(large, for: url, pointSize: 92)

        XCTAssertTrue(ClutterThumbnailCache.cached(url, pointSize: 46) === small)
        XCTAssertTrue(ClutterThumbnailCache.cached(url, pointSize: 92) === large)
    }
}
