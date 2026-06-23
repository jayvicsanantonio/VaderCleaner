// SimilarImageScanner.swift
// Finds visually near-identical images under a chosen folder by computing a Vision feature print per image and clustering by perceptual distance; returns groups keeping the highest-fidelity copy.

import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Top-level entry point for the My Clutter "Similar Images" card. Walks the
/// chosen folder for image files, computes a Vision feature print for each, and
/// clusters images whose pairwise feature-print distance falls below a
/// threshold. Each cluster of two or more becomes a `SimilarImageGroup`.
///
/// Feature-print extraction (real Vision work) is kept separate from the
/// clustering so the clustering can be unit-tested with a synthetic distance
/// matrix — the scan never fabricates data.
struct SimilarImageScanner {

    /// Image file extensions the scan considers. Lowercased; matched against the
    /// file's lowercased extension.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"
    ]

    /// Feature-print distance at or below which two images are treated as
    /// "similar". Vision distances grow with visual difference; ~0.35 catches
    /// near-identical shots (bursts, lightly edited copies) without merging
    /// merely thematically-related photos.
    static let defaultThreshold: Float = 0.35

    /// Upper bound on the number of images compared, so the O(n²) clustering and
    /// the per-image Vision pass stay bounded on huge libraries. The newest
    /// images are kept when the cap is hit, matching the card's "recently
    /// appeared" framing.
    static let defaultImageCap = 1500

    private let fileScanner: FileScanning
    private let roots: [URL]
    private let threshold: Float
    private let imageCap: Int
    /// Test seam: returns a feature print for a URL, or `nil` when the image
    /// can't be read. Production uses Vision; tests can stub it.
    private let featurePrint: @Sendable (URL) -> VNFeaturePrintObservation?

    init(
        fileScanner: FileScanning = FileScanner(),
        roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        threshold: Float = SimilarImageScanner.defaultThreshold,
        imageCap: Int = SimilarImageScanner.defaultImageCap,
        featurePrint: @escaping @Sendable (URL) -> VNFeaturePrintObservation? = SimilarImageScanner.visionFeaturePrint(for:)
    ) {
        self.fileScanner = fileScanner
        self.roots = roots
        self.threshold = threshold
        self.imageCap = imageCap
        self.featurePrint = featurePrint
    }

    /// Walks the root for images and returns similar-image groups, ordered by
    /// reclaimable bytes (largest payoff first). Honors `excluding` like the
    /// other feature scanners.
    func scan(
        excluding: [URL],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [SimilarImageGroup] {
        guard !roots.isEmpty else { return [] }

        // Collect candidate image files.
        var images: [ScannedFile] = []
        try await fileScanner.scan(
            roots: roots.map { ScanRoot(url: $0, category: .largeFile) },
            excluding: excluding,
            options: FileScanOptions(packagesAsFiles: true, skipsProtectedMediaStores: true),
            batchSize: FileScanner.defaultBatchSize,
            onProgress: onProgress
        ) { batch in
            for file in batch where Self.imageExtensions.contains(file.url.pathExtension.lowercased()) && file.size > 0 {
                images.append(file)
            }
            try Task.checkCancellation()
        }

        guard images.count > 1 else { return [] }

        // Keep the newest images when over the cap so the comparison stays
        // bounded; recency uses modified date, falling back to access date.
        if images.count > imageCap {
            images.sort { Self.recency($0) > Self.recency($1) }
            images = Array(images.prefix(imageCap))
        }

        // Compute one feature print per image; drop unreadable images. iCloud
        // placeholders are skipped so Vision never forces a slow on-demand
        // download (which otherwise stalls and makes the decode fail).
        var prints: [VNFeaturePrintObservation] = []
        var kept: [ScannedFile] = []
        for file in images {
            try Task.checkCancellation()
            guard CloudFileAvailability.isLocallyAvailable(file.url) else { continue }
            guard let print = featurePrint(file.url) else { continue }
            prints.append(print)
            kept.append(file)
        }

        guard kept.count > 1 else { return [] }

        // Cluster by perceptual distance, then build a group per cluster.
        let clusters = Self.cluster(count: kept.count, threshold: threshold) { i, j in
            Self.distance(prints[i], prints[j])
        }

        let groups = clusters.map { indices -> SimilarImageGroup in
            // Keep the largest file as the original (highest fidelity).
            let files = indices.map { kept[$0] }.sorted { $0.size > $1.size }
            return SimilarImageGroup(files: files)
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    // MARK: - Pure clustering

    /// Single-link clustering over `count` items using a union-find. Two items
    /// join the same cluster when their `distance` is non-nil and at or below
    /// `threshold`. Returns only clusters of two or more, each a sorted index
    /// list. Pure and side-effect-free so it is unit-testable with a synthetic
    /// distance function.
    static func cluster(
        count: Int,
        threshold: Float,
        distance: (Int, Int) -> Float?
    ) -> [[Int]] {
        guard count > 1 else { return [] }
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root {
                parent[root] = parent[parent[root]]
                root = parent[root]
            }
            return root
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        for i in 0..<count {
            for j in (i + 1)..<count {
                if let d = distance(i, j), d <= threshold { union(i, j) }
            }
        }

        var byRoot: [Int: [Int]] = [:]
        for i in 0..<count { byRoot[find(i), default: []].append(i) }
        return byRoot.values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    // MARK: - Vision

    /// The real feature-print extraction: decode the image and run Vision's
    /// feature-print request. Returns `nil` when the image can't be read or
    /// Vision produces no observation, so a bad image is simply skipped.
    static func visionFeaturePrint(for url: URL) -> VNFeaturePrintObservation? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// Perceptual distance between two feature prints, or `nil` if Vision can't
    /// compare them (e.g. mismatched element types).
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var value = Float(0)
        do {
            try a.computeDistance(&value, to: b)
        } catch {
            return nil
        }
        return value
    }

    /// Recency key used to keep the newest images when over the cap.
    private static func recency(_ file: ScannedFile) -> Date {
        file.lastModifiedDate ?? file.lastAccessDate ?? .distantPast
    }
}
