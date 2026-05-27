// BundledClamAVRuntimeTests.swift
// Verifies BundledClamAVRuntime creates the database directory and freshclam.conf under a writable root and never clobbers an existing conf.

import XCTest
@testable import VaderCleaner

final class BundledClamAVRuntimeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(root)
    }

    // MARK: - databaseDirectory

    func test_databaseDirectory_createsTheDirectoryUnderRoot() throws {
        let runtime = BundledClamAVRuntime(root: root)
        let db = try runtime.databaseDirectory()

        XCTAssertEqual(db, root.appendingPathComponent("db", isDirectory: true))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_databaseDirectory_isIdempotent() throws {
        let runtime = BundledClamAVRuntime(root: root)
        _ = try runtime.databaseDirectory()
        // A second call must not throw on "directory already exists".
        XCTAssertNoThrow(try runtime.databaseDirectory())
    }

    // MARK: - freshclamConfigFile

    func test_freshclamConfigFile_writesAConfPointingAtDatabaseDirectory() throws {
        let runtime = BundledClamAVRuntime(root: root)
        let conf = try runtime.freshclamConfigFile()

        XCTAssertEqual(
            conf,
            root.appendingPathComponent("etc/freshclam.conf", isDirectory: false)
        )

        let contents = try String(contentsOf: conf, encoding: .utf8)
        // The conf must specify a mirror AND a database directory — freshclam
        // refuses to start without either.
        XCTAssertTrue(
            contents.contains("DatabaseMirror database.clamav.net"),
            "conf must name a mirror; freshclam exits with no work otherwise"
        )
        let expectedDBLine = "DatabaseDirectory \(root.appendingPathComponent("db").path)"
        XCTAssertTrue(
            contents.contains(expectedDBLine),
            "conf must point freshclam at our writable db dir; got:\n\(contents)"
        )
        // Homebrew's sample conf ships with `Example` uncommented to force
        // users to edit it before use; ours must not — freshclam refuses to
        // start while that token is present.
        XCTAssertFalse(
            contents.split(separator: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "Example"
            }),
            "conf must not contain the bare `Example` token"
        )
    }

    func test_freshclamConfigFile_doesNotClobberAnExistingConf() throws {
        let runtime = BundledClamAVRuntime(root: root)
        let conf = try runtime.freshclamConfigFile()
        let userEdited = "# user-edited\nDatabaseMirror mirror.example.com\n"
        try userEdited.write(to: conf, atomically: true, encoding: .utf8)

        _ = try runtime.freshclamConfigFile()

        let after = try String(contentsOf: conf, encoding: .utf8)
        XCTAssertEqual(after, userEdited,
                       "subsequent calls must leave a user-edited conf intact")
    }

    // MARK: - bundledCVDCertsDirectory

    func test_bundledCVDCertsDirectory_returnsURLWhenCertFilePresentUnderBundleResources() throws {
        // The cert directory lives inside the read-only .app bundle, so
        // we model it with an injected bundle-resource URL rather than
        // reaching for the real Bundle.main.
        let fakeResources = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(fakeResources) }
        let certs = fakeResources.appendingPathComponent("clamav/certs", isDirectory: true)
        try FileManager.default.createDirectory(at: certs, withIntermediateDirectories: true)
        try Data().write(to: certs.appendingPathComponent("clamav.crt"))

        let runtime = BundledClamAVRuntime(root: root, bundleResources: fakeResources)
        XCTAssertEqual(runtime.bundledCVDCertsDirectory(), certs)
    }

    func test_bundledCVDCertsDirectory_isNilWhenNoCertShipped() throws {
        let fakeResources = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(fakeResources) }
        // No certs/ written — represents a dev build that opts out of
        // bundling. freshclam will fall back to its compiled-in path
        // (and likely error), which the runner surfaces honestly.
        let runtime = BundledClamAVRuntime(root: root, bundleResources: fakeResources)
        XCTAssertNil(runtime.bundledCVDCertsDirectory())
    }
}
