// SimilarImageScannerDecodeTests.swift
// Pins how SimilarImageScanner decodes an image before Vision sees it: the file's EXIF orientation is applied, so a photo tagged sideways still matches its upright twin.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import VaderCleaner

final class SimilarImageScannerDecodeTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimilarImageScannerDecodeTests/\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    /// The pair this is really about: one photo, saved twice, differing only
    /// in whether the rotation lives in the pixels or in the orientation tag.
    /// That is what a phone transfer or a re-export produces, and before the
    /// decode applied the tag the two never clustered.
    func test_visionFeaturePrint_appliesEXIFOrientation() throws {
        let upright = try writeJPEG("upright.jpg", rotatingPixels: false, orientation: .up)
        // `.right` is EXIF orientation 6 — "the stored pixels need a quarter
        // turn to display correctly", which is exactly what the fixture does.
        let tagged = try writeJPEG("tagged.jpg", rotatingPixels: true, orientation: .right)

        let distance = try distanceBetween(upright, tagged)

        XCTAssertLessThanOrEqual(
            distance, SimilarImageScanner.defaultThreshold,
            "an orientation-tagged copy should match its upright twin (distance \(distance))"
        )
    }

    /// The control the test above needs to mean anything: proof the tag is
    /// what closed the gap, rather than Vision shrugging at rotation.
    ///
    /// Deliberately a comparison and not a threshold. The same pixels with no
    /// tag land at roughly 0.30 on this fixture — under `defaultThreshold`
    /// already, because a quarter turn preserves the colour makeup of large
    /// flat regions and a feature print notices. So "untagged is far away" is
    /// simply not true here, and asserting it would be pinning a number that
    /// says nothing about orientation. What does say something is that
    /// honouring the tag collapses the distance by an order of magnitude.
    func test_visionFeaturePrint_orientationTagIsWhatClosesTheGap() throws {
        let upright = try writeJPEG("upright.jpg", rotatingPixels: false, orientation: .up)
        let tagged = try writeJPEG("tagged.jpg", rotatingPixels: true, orientation: .right)
        let untagged = try writeJPEG("untagged.jpg", rotatingPixels: true, orientation: .up)

        let withTag = try distanceBetween(upright, tagged)
        let withoutTag = try distanceBetween(upright, untagged)

        XCTAssertLessThan(
            withTag, withoutTag / 2,
            "honouring the orientation tag barely moved the distance "
                + "(tagged \(withTag), untagged \(withoutTag)) — is the transform being applied?"
        )
    }

    // MARK: - Helpers

    private func distanceBetween(_ lhs: URL, _ rhs: URL) throws -> Float {
        let left = try XCTUnwrap(SimilarImageScanner.visionFeaturePrint(for: lhs),
                                 "no feature print for \(lhs.lastPathComponent)")
        let right = try XCTUnwrap(SimilarImageScanner.visionFeaturePrint(for: rhs),
                                  "no feature print for \(rhs.lastPathComponent)")
        return try XCTUnwrap(SimilarImageScanner.distance(left, right))
    }

    /// Writes a square, strongly asymmetric image so a quarter turn is
    /// unmistakable. Square on purpose: a 90° rotation keeps the dimensions,
    /// which keeps the fixture about orientation and nothing else.
    @discardableResult
    private func writeJPEG(
        _ name: String,
        rotatingPixels: Bool,
        orientation: CGImagePropertyOrientation
    ) throws -> URL {
        var image = try drawAsymmetricSquare()
        if rotatingPixels {
            image = try rotatedQuarterTurn(image)
        }

        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func drawAsymmetricSquare() throws -> CGImage {
        let side = 900
        let context = try makeContext(width: side, height: side)

        context.setFillColor(red: 0.1, green: 0.15, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // A bright block in one corner and a bar along one edge — enough that
        // a quarter turn moves both somewhere Vision can tell apart.
        let size = CGFloat(side)
        context.setFillColor(red: 0.95, green: 0.75, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: size * 0.6, width: size * 0.4, height: size * 0.4))
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size * 0.08, height: size))

        return try XCTUnwrap(context.makeImage())
    }

    private func rotatedQuarterTurn(_ image: CGImage) throws -> CGImage {
        let context = try makeContext(width: image.height, height: image.width)
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
    }
}
