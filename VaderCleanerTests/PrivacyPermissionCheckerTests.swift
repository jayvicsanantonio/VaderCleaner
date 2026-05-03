// PrivacyPermissionCheckerTests.swift
// Tests that PrivacyPermissionChecker.hasFullDiskAccess(testPath:) probes paths via real file reads.

import XCTest
@testable import VaderCleaner

final class PrivacyPermissionCheckerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestHelpers.createTempDirectory()
    }

    override func tearDown() {
        if let tempDir { TestHelpers.tearDownTempDirectory(tempDir) }
        tempDir = nil
        super.tearDown()
    }

    func test_hasFullDiskAccess_returnsTrue_forReadableTempFile() throws {
        let file = try TestHelpers.createDummyFile(named: "readable.bin", size: 16, in: tempDir)
        XCTAssertTrue(PrivacyPermissionChecker.hasFullDiskAccess(testPath: file))
    }

    func test_hasFullDiskAccess_returnsFalse_forNonexistentPath() {
        let missing = tempDir.appendingPathComponent("does_not_exist.bin")
        XCTAssertFalse(PrivacyPermissionChecker.hasFullDiskAccess(testPath: missing))
    }

    func test_hasFullDiskAccess_returnsFalse_forDirectoryPath() {
        // Real file reads fail on directories — relying on this distinguishes a granted-access
        // directory listing (which fileExists would confirm) from an actual readable file.
        XCTAssertFalse(PrivacyPermissionChecker.hasFullDiskAccess(testPath: tempDir))
    }

    func test_hasFullDiskAccess_defaultPath_returnsBool() {
        // Asserting only that the default-path overload returns *some* Bool — the actual
        // result depends on the host machine's TCC state, which would break CI either way
        // if asserted directly.
        let result: Bool = PrivacyPermissionChecker.hasFullDiskAccess()
        _ = result
    }

    func test_defaultTestPath_endsWithTCCdb() {
        // Smoke test: the canonical FDA-gated path is the TCC database.
        XCTAssertTrue(
            PrivacyPermissionChecker.defaultTestPath.path.hasSuffix(
                "Library/Application Support/com.apple.TCC/TCC.db"
            )
        )
    }
}
