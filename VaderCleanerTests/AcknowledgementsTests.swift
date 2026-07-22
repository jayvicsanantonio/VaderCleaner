// AcknowledgementsTests.swift
// Tests that the bundled open-source license text is located, concatenated, and degrades gracefully when the staged files are missing.

import XCTest
@testable import VaderCleaner

final class AcknowledgementsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcknowledgementsTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: licenseDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    /// Mirrors the layout `Scripts/stage-clamav.sh` rsyncs into the app bundle:
    /// `<Resources>/clamav/LICENSES/`.
    private var licenseDirectory: URL {
        root.appendingPathComponent("clamav/LICENSES", isDirectory: true)
    }

    private func write(_ contents: String, to name: String) throws {
        try contents.write(
            to: licenseDirectory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func test_load_returnsNil_whenNothingIsStaged() throws {
        try FileManager.default.removeItem(at: licenseDirectory)

        XCTAssertNil(Acknowledgements.load(resourcesURL: root))
    }

    func test_load_returnsNil_whenThereIsNoBundleResourceDirectory() {
        XCTAssertNil(Acknowledgements.load(resourcesURL: nil))
    }

    func test_load_includesTheLicenseText() throws {
        try write("ClamAV is distributed under the GNU GPL, version 2.", to: "LICENSE-clamav.txt")

        let text = try XCTUnwrap(Acknowledgements.load(resourcesURL: root))

        XCTAssertTrue(text.contains("GNU GPL, version 2"))
    }

    /// The README carries the "where to get the source" offer that GPL-2.0 §3
    /// requires, so it must be surfaced alongside the license itself.
    func test_load_leadsWithTheReadmeThenTheLicense() throws {
        try write("Sources are available at: https://example.invalid/clamav", to: "README.txt")
        try write("GPL-2.0 terms here.", to: "LICENSE-clamav.txt")

        let text = try XCTUnwrap(Acknowledgements.load(resourcesURL: root))
        let readmeIndex = try XCTUnwrap(text.range(of: "Sources are available at"))
        let licenseIndex = try XCTUnwrap(text.range(of: "GPL-2.0 terms here"))

        XCTAssertTrue(
            readmeIndex.lowerBound < licenseIndex.lowerBound,
            "the source offer should introduce the license text"
        )
    }

    func test_load_survivesAMissingReadme() throws {
        try write("GPL-2.0 terms here.", to: "LICENSE-clamav.txt")

        let text = try XCTUnwrap(Acknowledgements.load(resourcesURL: root))

        XCTAssertTrue(text.contains("GPL-2.0 terms here"))
    }

    /// Unknown files dropped into the staged directory should still be shown —
    /// bundling another dependency must not silently omit its license.
    func test_load_includesAnyOtherStagedLicenseFile() throws {
        try write("OpenSSL license terms.", to: "LICENSE-openssl.txt")

        let text = try XCTUnwrap(Acknowledgements.load(resourcesURL: root))

        XCTAssertTrue(text.contains("OpenSSL license terms"))
    }

    func test_load_isStableAcrossCalls() throws {
        try write("Readme.", to: "README.txt")
        try write("A terms.", to: "LICENSE-a.txt")
        try write("B terms.", to: "LICENSE-b.txt")

        XCTAssertEqual(Acknowledgements.load(resourcesURL: root), Acknowledgements.load(resourcesURL: root))
    }
}
