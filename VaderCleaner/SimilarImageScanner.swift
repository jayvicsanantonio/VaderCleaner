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

    /// Feature prints computed at once. The work here is decode-plus-Vision,
    /// so unlike `DuplicateScanner`'s I/O-bound hashing this tracks core
    /// count — capped so a very wide machine doesn't hold more of the
    /// cooperative pool than the scan can usefully use.
    static let maxConcurrentFeaturePrints = min(ProcessInfo.processInfo.activeProcessorCount, 8)

    /// Longest edge, in pixels, the feature-print decode is allowed to
    /// produce. Vision downsamples to its own small working size regardless,
    /// so decoding a 48-megapixel photo at full resolution buys nothing and
    /// costs both the time and the ~200 MB peak of the full decode.
    static let featurePrintMaxPixelSize = 512

    /// Ferries a Vision observation out of the concurrent feature-print pass.
    ///
    /// `@unchecked Sendable` because Vision is not Sendable-audited, though
    /// its observations are immutable results. The invariant that backs it:
    /// each observation is created inside a single task, is never mutated
    /// after Vision returns it, and is handed to exactly one consumer.
    private struct FeaturePrint: @unchecked Sendable {
        let observation: VNFeaturePrintObservation
    }

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
        ) { [libraryPath = Self.userLibraryPath()] batch in
            for file in batch where Self.imageExtensions.contains(file.url.pathExtension.lowercased())
                && file.size > 0
                && Self.isUserPhotoCandidate(file.url, libraryPath: libraryPath) {
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

        // Compute one feature print per image; drop unreadable images. This
        // is the expensive half of the scan — a decode and a Vision pass per
        // image — so it runs with bounded concurrency rather than serially,
        // which left every core but one idle. Results are slotted by index,
        // so completion order doesn't affect the outcome: `kept` and `prints`
        // stay in lockstep and `cluster` indexes into both.
        let computed = try await withThrowingTaskGroup(
            of: (Int, FeaturePrint?).self
        ) { group -> [FeaturePrint?] in
            var results = [FeaturePrint?](repeating: nil, count: images.count)
            var nextIndex = 0
            func addTaskIfNeeded() {
                guard nextIndex < images.count else { return }
                let index = nextIndex
                let url = images[index].url
                nextIndex += 1
                group.addTask { [featurePrint] in
                    // iCloud placeholders are skipped so Vision never forces
                    // a slow on-demand download (which otherwise stalls and
                    // makes the decode fail).
                    guard CloudFileAvailability.isLocallyAvailable(url) else { return (index, nil) }
                    return (index, featurePrint(url).map(FeaturePrint.init(observation:)))
                }
            }
            for _ in 0..<Self.maxConcurrentFeaturePrints { addTaskIfNeeded() }
            while let (index, computedPrint) = try await group.next() {
                results[index] = computedPrint
                try Task.checkCancellation()
                addTaskIfNeeded()
            }
            return results
        }

        var prints: [VNFeaturePrintObservation] = []
        var kept: [ScannedFile] = []
        for (file, computedPrint) in zip(images, computed) {
            guard let computedPrint else { continue }
            prints.append(computedPrint.observation)
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

    // MARK: - Scope

    /// The user's `~/Library` path, computed once per scan so the per-file
    /// eligibility check doesn't re-resolve the home directory for every image.
    nonisolated static func userLibraryPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
    }

    /// Whether `url` is somewhere worth scanning for the user's *own* similar
    /// photos. Rejects anything under `~/Library` — app caches and containers
    /// such as the wallpaper-extension image cache, which are near-identical by
    /// design, aren't photos a person means to de-duplicate, and are regenerated
    /// by the OS. The trailing separator keeps a sibling like `~/LibraryNotes`
    /// from matching the `~/Library` prefix.
    nonisolated static func isUserPhotoCandidate(_ url: URL, libraryPath: String) -> Bool {
        !url.path.hasPrefix(libraryPath + "/")
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
    ///
    /// The decode is bounded to `featurePrintMaxPixelSize` rather than full
    /// resolution. `…FromImageAlways` because an embedded thumbnail may be
    /// absent or too small to be worth a feature print, and going through
    /// the thumbnail API is what lets ImageIO downsample during the decode
    /// instead of after it.
    static func visionFeaturePrint(for url: URL) -> VNFeaturePrintObservation? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: featurePrintMaxPixelSize
        ]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
