// SimilarImageScannerConcurrencyTests.swift
// Drives SimilarImageScanner end-to-end over generated image files, pinning that the concurrent feature-print pass groups images exactly as a serial one would.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import VaderCleaner

final class SimilarImageScannerConcurrencyTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimilarImageScannerConcurrencyTests/\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    /// Holds real Vision observations for the injected feature-print seam.
    ///
    /// `@unchecked Sendable`: populated once before the scan starts and only
    /// read afterwards, so there is no concurrent mutation to protect.
    /// Keyed by filename, not URL: the scan reports canonical paths
    /// (`/private/var/…`) where the fixtures were written through the
    /// symlinked spelling (`/var/…`), so URLs from the two sides don't
    /// compare equal. Filenames are unique within the fixture directory.
    private final class PrintTable: @unchecked Sendable {
        private let prints: [String: VNFeaturePrintObservation]
        private let order: [String: Int]
        private let count: Int

        init(prints: [String: VNFeaturePrintObservation], order: [String: Int]) {
            self.prints = prints
            self.order = order
            self.count = prints.count
        }

        /// Returns the observation, having stalled for longer the *earlier*
        /// the image appears in the list. That inverts completion order
        /// relative to submission order, which is what would expose results
        /// being appended as they arrive rather than slotted by index.
        func observation(for url: URL) -> VNFeaturePrintObservation? {
            let name = url.lastPathComponent
            let position = order[name] ?? 0
            Thread.sleep(forTimeInterval: Double(count - position) * 0.01)
            return prints[name]
        }
    }

    /// The regression this guards: the feature-print pass runs concurrently,
    /// so `kept` and `prints` are built from indexed slots rather than by
    /// appending in completion order. If those two ever drift apart, images
    /// get clustered against another image's feature print — the scan would
    /// still return plausible-looking groups made of the wrong files.
    ///
    /// Vision's absolute distances aren't asserted anywhere here: the
    /// expected grouping is derived from the same real observations, so the
    /// test pins concurrent-equals-serial rather than any particular
    /// similarity verdict.
    func test_scan_groupsIdenticallyToASerialFeaturePrintPass() async throws {
        let urls = try writeImages()

        // Real Vision work, computed serially and in order — the baseline.
        var prints: [String: VNFeaturePrintObservation] = [:]
        var order: [String: Int] = [:]
        for (index, url) in urls.enumerated() {
            prints[url.lastPathComponent] = try XCTUnwrap(
                SimilarImageScanner.visionFeaturePrint(for: url),
                "no feature print for \(url.lastPathComponent)"
            )
            order[url.lastPathComponent] = index
        }

        let ordered = urls.compactMap { prints[$0.lastPathComponent] }
        let expected = SimilarImageScanner.cluster(
            count: ordered.count,
            threshold: SimilarImageScanner.defaultThreshold
        ) { i, j in
            SimilarImageScanner.distance(ordered[i], ordered[j])
        }
        let expectedGroups = Set(expected.map { indices in
            Set(indices.map { urls[$0].lastPathComponent })
        })

        let table = PrintTable(prints: prints, order: order)
        let scanner = SimilarImageScanner(
            roots: [directory],
            featurePrint: { table.observation(for: $0) }
        )
        let groups = try await scanner.scan(excluding: [])
        let actualGroups = Set(groups.map { group in
            Set(group.files.map { $0.url.lastPathComponent })
        })

        XCTAssertFalse(expectedGroups.isEmpty, "the fixtures produced no clusters to compare")
        XCTAssertFalse(actualGroups.isEmpty, "the scan found no images under \(directory.path)")
        XCTAssertEqual(actualGroups, expectedGroups)
    }

    /// Every file the scan keeps must be one it actually produced a feature
    /// print for — a skipped image must not shift the images after it onto
    /// the wrong print.
    func test_scan_skippedImagesDoNotShiftTheRest() async throws {
        let urls = try writeImages()
        let skipped = urls[1]

        var prints: [String: VNFeaturePrintObservation] = [:]
        var order: [String: Int] = [:]
        for (index, url) in urls.enumerated() where url != skipped {
            prints[url.lastPathComponent] = try XCTUnwrap(SimilarImageScanner.visionFeaturePrint(for: url))
            order[url.lastPathComponent] = index
        }

        let table = PrintTable(prints: prints, order: order)
        let scanner = SimilarImageScanner(
            roots: [directory],
            featurePrint: { table.observation(for: $0) }
        )
        let groups = try await scanner.scan(excluding: [])

        let grouped = groups.flatMap { $0.files.map(\.url.lastPathComponent) }
        // Non-vacuous: the other patterns must still have paired up, so an
        // empty result can't quietly satisfy the assertion below.
        XCTAssertFalse(grouped.isEmpty, "the scan found no groups at all")
        XCTAssertFalse(grouped.contains(skipped.lastPathComponent),
                       "an image with no feature print was still grouped")
        // The skipped image's partner loses its pair and drops out with it;
        // every other pattern is untouched.
        XCTAssertFalse(grouped.contains(urls[0].lastPathComponent),
                       "a singleton was reported as a group")
    }

    // MARK: - Fixtures

    /// Four visually distinct patterns, each written twice with a small
    /// offset so the pair is near-identical without being byte-identical.
    /// Written large enough that the decode path is doing real work.
    private func writeImages() throws -> [URL] {
        var urls: [URL] = []
        for pattern in 0..<4 {
            for copy in 0..<2 {
                let url = directory.appendingPathComponent("pattern\(pattern)-copy\(copy).png")
                try write(pattern: pattern, offset: CGFloat(copy) * 3, to: url)
                urls.append(url)
            }
        }
        return urls
    }

    private func write(pattern: Int, offset: CGFloat, to url: URL) throws {
        let side = 1200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        let backgrounds: [(CGFloat, CGFloat, CGFloat)] = [
            (0.9, 0.1, 0.1), (0.1, 0.2, 0.9), (0.1, 0.7, 0.2), (0.95, 0.85, 0.1)
        ]
        let background = backgrounds[pattern % backgrounds.count]
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // A different shape per pattern, so the four aren't merely four hues.
        context.setFillColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        let size = CGFloat(side)
        switch pattern % 4 {
        case 0:
            context.fill(CGRect(x: offset, y: 0, width: size / 2, height: size))
        case 1:
            context.fillEllipse(in: CGRect(x: size / 4 + offset, y: size / 4,
                                           width: size / 2, height: size / 2))
        case 2:
            for stripe in stride(from: CGFloat(0), to: size, by: size / 10) {
                context.fill(CGRect(x: stripe + offset, y: 0, width: size / 20, height: size))
            }
        default:
            context.fill(CGRect(x: 0, y: size / 3 + offset, width: size, height: size / 3))
        }

        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
