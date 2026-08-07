// UpdateInstallToolsTests.swift
// Tests the live update-install layer's filename handling, which decides where a feed-supplied download is allowed to land on disk.

import XCTest
@testable import VaderCleaner

final class UpdateInstallToolsTests: XCTestCase {

    private let workingDirectory = URL(
        fileURLWithPath: "/tmp/VaderCleanerUpdates/session", isDirectory: true
    )

    /// Enclosure URLs a hostile or compromised appcast could publish. Each
    /// one relies on `URL.lastPathComponent` percent-decoding its escapes,
    /// which is what turned a filename into a relative path.
    private let hostileURLs = [
        "https://evil.example.com/a/..%2F..%2F..%2Fpwned.zip",
        "https://evil.example.com/%2e%2e%2f%2e%2e%2fpwned.zip",
        "https://evil.example.com/dir%2Fsub%2Fpwned.zip",
        "https://evil.example.com/..",
        "https://evil.example.com/%2F%2Fetc%2Fpwned",
        "https://evil.example.com/x.%2F%2E%2E"
    ]

    // MARK: - Containment

    /// The load-bearing guarantee: whatever the feed names its enclosure,
    /// the download lands inside the scratch directory we own. This runs
    /// before the signature check and before `UpdateInstallGate`, so it is
    /// the only thing standing between a hostile appcast and an arbitrary
    /// file write.
    func test_downloadFilename_keepsHostileURLsInsideTheWorkingDirectory() throws {
        for string in hostileURLs {
            let url = try XCTUnwrap(URL(string: string), string)
            let destination = workingDirectory
                .appendingPathComponent(UpdateInstallTools.downloadFilename(for: url), isDirectory: false)
                .standardizedFileURL

            XCTAssertEqual(
                destination.deletingLastPathComponent().standardizedFileURL.path,
                workingDirectory.standardizedFileURL.path,
                "\(string) escaped the working directory as \(destination.path)"
            )
        }
    }

    /// A filename is a single path component. Anything carrying a separator
    /// is already a path, whatever it decodes from.
    func test_downloadFilename_neverContainsAPathSeparator() throws {
        for string in hostileURLs {
            let url = try XCTUnwrap(URL(string: string), string)
            let name = UpdateInstallTools.downloadFilename(for: url)
            XCTAssertFalse(name.contains("/"), "\(string) produced \(name)")
            XCTAssertNotEqual(name, "..", string)
            XCTAssertNotEqual(name, ".", string)
        }
    }

    // MARK: - Extension handling

    /// The extension has to survive: `extractApplication(from:)` switches on
    /// it to pick between `ditto` and `hdiutil`, so discarding it would turn
    /// every update into an unsupported-archive refusal.
    func test_downloadFilename_preservesTheArchiveExtension() throws {
        let cases = [
            "https://example.com/VaderCleaner-2.0.zip": "update.zip",
            "https://example.com/downloads/App.dmg": "update.dmg",
            "https://example.com/App.ZIP": "update.zip",
            "https://example.com/App-1.2.3.zip?token=abc": "update.zip"
        ]

        for (string, expected) in cases {
            let url = try XCTUnwrap(URL(string: string), string)
            XCTAssertEqual(UpdateInstallTools.downloadFilename(for: url), expected, string)
        }
    }

    /// An extension that is itself a path fragment is dropped rather than
    /// sanitised, so the containment guarantee can't be smuggled past by
    /// hiding the escape after the last dot.
    func test_downloadFilename_dropsNonAlphanumericExtensions() throws {
        let cases = [
            "https://example.com/archive",
            "https://example.com/x.%2F%2E%2E",
            "https://example.com/x.zip%2Fevil"
        ]

        for string in cases {
            let url = try XCTUnwrap(URL(string: string), string)
            XCTAssertEqual(UpdateInstallTools.downloadFilename(for: url), "update", string)
        }
    }

    /// A dropped extension reaches `extractApplication(from:)` as an empty
    /// one, which is an unsupported archive — a refusal, not a guess. The
    /// alternative (defaulting to `.zip`) would feed an unknown payload to
    /// `ditto`, which is exactly the parser we don't want to reach.
    func test_downloadFilename_withoutExtensionIsNotTreatedAsAnArchive() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/archive"))
        let destination = workingDirectory
            .appendingPathComponent(UpdateInstallTools.downloadFilename(for: url), isDirectory: false)
        XCTAssertTrue(destination.pathExtension.isEmpty)
    }
}
