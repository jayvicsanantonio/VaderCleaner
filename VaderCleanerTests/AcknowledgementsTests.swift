// AcknowledgementsTests.swift
// Tests that the bundled open-source license text is located, concatenated, and degrades gracefully when the staged files are missing.

import Foundation
import Testing
@testable import VaderCleaner

final class AcknowledgementsTests {

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcknowledgementsTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: licenseDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
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

    @Test
    func load_returnsNil_whenNothingIsStaged() throws {
        try FileManager.default.removeItem(at: licenseDirectory)

        #expect(Acknowledgements.load(resourcesURL: root) == nil)
    }

    @Test
    func load_returnsNil_whenThereIsNoBundleResourceDirectory() {
        #expect(Acknowledgements.load(resourcesURL: nil) == nil)
    }

    @Test
    func load_includesTheLicenseText() throws {
        try write("ClamAV is distributed under the GNU GPL, version 2.", to: "LICENSE-clamav.txt")

        let text = try #require(Acknowledgements.load(resourcesURL: root))

        #expect(text.contains("GNU GPL, version 2"))
    }

    /// The README carries the "where to get the source" offer that GPL-2.0 §3
    /// requires, so it must be surfaced alongside the license itself.
    @Test
    func load_leadsWithTheReadmeThenTheLicense() throws {
        try write("Sources are available at: https://example.invalid/clamav", to: "README.txt")
        try write("GPL-2.0 terms here.", to: "LICENSE-clamav.txt")

        let text = try #require(Acknowledgements.load(resourcesURL: root))
        let readmeIndex = try #require(text.range(of: "Sources are available at"))
        let licenseIndex = try #require(text.range(of: "GPL-2.0 terms here"))

        #expect(readmeIndex.lowerBound < licenseIndex.lowerBound, "the source offer should introduce the license text")
    }

    @Test
    func load_survivesAMissingReadme() throws {
        try write("GPL-2.0 terms here.", to: "LICENSE-clamav.txt")

        let text = try #require(Acknowledgements.load(resourcesURL: root))

        #expect(text.contains("GPL-2.0 terms here"))
    }

    /// Unknown files dropped into the staged directory should still be shown —
    /// bundling another dependency must not silently omit its license.
    @Test
    func load_includesAnyOtherStagedLicenseFile() throws {
        try write("OpenSSL license terms.", to: "LICENSE-openssl.txt")

        let text = try #require(Acknowledgements.load(resourcesURL: root))

        #expect(text.contains("OpenSSL license terms"))
    }

    @Test
    func load_isStableAcrossCalls() throws {
        try write("Readme.", to: "README.txt")
        try write("A terms.", to: "LICENSE-a.txt")
        try write("B terms.", to: "LICENSE-b.txt")

        #expect(Acknowledgements.load(resourcesURL: root) == Acknowledgements.load(resourcesURL: root))
    }
}
