// SimilarImageScannerTests.swift
// Pins the pure perceptual-clustering core of SimilarImageScanner: items merge only when their distance is within threshold, singletons are dropped, and clusters are returned as sorted index groups.

import XCTest
@testable import VaderCleanerCore

final class SimilarImageScannerTests: XCTestCase {

    /// A symmetric distance matrix as a lookup; missing pairs are treated as far.
    private func distance(_ matrix: [[Float]]) -> (Int, Int) -> Float? {
        { i, j in matrix[i][j] }
    }

    func test_mergesItemsWithinThreshold() {
        // 0 & 1 are close; 2 is far from both.
        let matrix: [[Float]] = [
            [0.0, 0.1, 0.9],
            [0.1, 0.0, 0.8],
            [0.9, 0.8, 0.0],
        ]
        let clusters = SimilarImageScanner.cluster(count: 3, threshold: 0.35, distance: distance(matrix))

        XCTAssertEqual(clusters, [[0, 1]], "Only the two near images should cluster; the far one is a singleton and dropped")
    }

    func test_chainDoesNotMergeItemsThatAreFarApart() {
        // 0~1 and 1~2 but 0 and 2 are far. A group promises its images look
        // alike, so a shared neighbour can't pull 0 and 2 together.
        let matrix: [[Float]] = [
            [0.0, 0.2, 0.9],
            [0.2, 0.0, 0.2],
            [0.9, 0.2, 0.0],
        ]
        let clusters = SimilarImageScanner.cluster(count: 3, threshold: 0.35, distance: distance(matrix))

        XCTAssertEqual(clusters, [[0, 1]], "Every pair in a cluster must be within the threshold")
    }

    func test_noClustersWhenAllFarApart() {
        let matrix: [[Float]] = [
            [0.0, 0.9, 0.9],
            [0.9, 0.0, 0.9],
            [0.9, 0.9, 0.0],
        ]
        let clusters = SimilarImageScanner.cluster(count: 3, threshold: 0.35, distance: distance(matrix))

        XCTAssertTrue(clusters.isEmpty, "No pair within threshold means no clusters")
    }

    func test_nilDistanceNeverMerges() {
        let clusters = SimilarImageScanner.cluster(count: 2, threshold: 1.0) { _, _ in nil }
        XCTAssertTrue(clusters.isEmpty, "An uncomparable pair (nil distance) must not merge")
    }

    // MARK: - Scope

    /// System caches under `~/Library` (e.g. the wallpaper-extension image
    /// cache) are excluded; the user's real photo locations are kept.
    func test_isUserPhotoCandidate_excludesLibraryCaches() {
        let lib = "/Users/x/Library"
        XCTAssertFalse(SimilarImageScanner.isUserPhotoCandidate(
            URL(fileURLWithPath: "/Users/x/Library/Containers/com.apple.wallpaper/img.bmp"),
            libraryPath: lib
        ))
        XCTAssertTrue(SimilarImageScanner.isUserPhotoCandidate(
            URL(fileURLWithPath: "/Users/x/Pictures/vacation.jpg"), libraryPath: lib
        ))
        XCTAssertTrue(SimilarImageScanner.isUserPhotoCandidate(
            URL(fileURLWithPath: "/Users/x/Screenshots/shot.png"), libraryPath: lib
        ))
    }

    /// A sibling directory that merely starts with "Library" must not be
    /// swept in by the prefix check.
    func test_isUserPhotoCandidate_prefixSiblingNotExcluded() {
        XCTAssertTrue(SimilarImageScanner.isUserPhotoCandidate(
            URL(fileURLWithPath: "/Users/x/LibraryNotes/a.jpg"), libraryPath: "/Users/x/Library"
        ))
    }

    func test_returnsMultipleDisjointClusters() {
        let matrix: [[Float]] = [
            [0.0, 0.1, 0.9, 0.9],
            [0.1, 0.0, 0.9, 0.9],
            [0.9, 0.9, 0.0, 0.1],
            [0.9, 0.9, 0.1, 0.0],
        ]
        let clusters = SimilarImageScanner
            .cluster(count: 4, threshold: 0.35, distance: distance(matrix))
            .sorted { $0[0] < $1[0] }

        XCTAssertEqual(clusters, [[0, 1], [2, 3]])
    }
}
