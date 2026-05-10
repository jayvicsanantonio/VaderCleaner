// HelperDeletionPolicyTests.swift
// Security tests for privileged helper deletion path validation.

import XCTest
@testable import VaderCleaner

final class HelperDeletionPolicyTests: XCTestCase {
    private var tempRoot: URL!
    private var policy: HelperDeletionPolicy!
    private var cacheRoot: URL!
    private var logsRoot: URL!
    private var varFoldersRoot: URL!
    private var applicationsRoot: URL!
    private var libraryApplicationSupportRoot: URL!
    private var frameworksRoot: URL!
    private var volumesRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()

        cacheRoot = tempRoot.appendingPathComponent("Library/Caches", isDirectory: true)
        logsRoot = tempRoot.appendingPathComponent("Library/Logs", isDirectory: true)
        varFoldersRoot = tempRoot.appendingPathComponent("private/var/folders", isDirectory: true)
        applicationsRoot = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        libraryApplicationSupportRoot = tempRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
        frameworksRoot = tempRoot.appendingPathComponent("Library/Frameworks", isDirectory: true)
        volumesRoot = tempRoot.appendingPathComponent("Volumes", isDirectory: true)

        let roots: [URL] = [
            cacheRoot,
            logsRoot,
            varFoldersRoot,
            applicationsRoot,
            libraryApplicationSupportRoot,
            frameworksRoot,
            volumesRoot
        ]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        policy = HelperDeletionPolicy(
            allowedDescendantRoots: [cacheRoot, logsRoot, varFoldersRoot],
            allowedLanguageResourceRoots: [
                applicationsRoot,
                libraryApplicationSupportRoot,
                frameworksRoot
            ],
            volumesRoot: volumesRoot
        )
    }

    override func tearDown() {
        if let tempRoot {
            TestHelpers.tearDownTempDirectory(tempRoot)
        }
        tempRoot = nil
        policy = nil
        super.tearDown()
    }

    func test_validateDeletionPath_acceptsAllowedSystemCacheDescendant() throws {
        let url = cacheRoot.appendingPathComponent("com.example/file.bin")

        XCTAssertEqual(try policy.validateDeletionPath(url.path), url.standardizedFileURL)
    }

    func test_validateDeletionPath_acceptsAllowedVolumeTrashDescendant() throws {
        let url = volumesRoot
            .appendingPathComponent("External", isDirectory: true)
            .appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent("501", isDirectory: true)
            .appendingPathComponent("file.bin")

        XCTAssertEqual(try policy.validateDeletionPath(url.path), url.standardizedFileURL)
    }

    func test_validateDeletionPath_acceptsLanguageResourceFileInsideAppBundle() throws {
        let url = applicationsRoot
            .appendingPathComponent("Example.app/Contents/Resources/fr.lproj/Localizable.strings")

        XCTAssertEqual(try policy.validateDeletionPath(url.path), url.standardizedFileURL)
    }

    func test_validateDeletionPath_rejectsTraversalOutOfAllowedRoot() throws {
        let path = cacheRoot
            .appendingPathComponent("../Preferences/com.apple.test.plist")
            .path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
    }

    func test_validateDeletionPath_rejectsAllowedRootItself() {
        XCTAssertThrowsError(try policy.validateDeletionPath(cacheRoot.path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(cacheRoot.path))
        }
    }

    func test_validateDeletionPath_rejectsFilesystemRoot() {
        XCTAssertThrowsError(try policy.validateDeletionPath("/")) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .rootPath("/"))
        }
    }

    func test_validateDeletionPath_rejectsBoundaryPrefixCollision() {
        let path = tempRoot
            .appendingPathComponent("Library/CachesSymlink/file.bin")
            .path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
    }

    func test_validateDeletionPath_rejectsSymlinkEscapeAfterResolution() throws {
        let outside = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = try TestHelpers.createDummyFile(named: "secret.txt", size: 1, in: outside)
        let link = cacheRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let path = link.appendingPathComponent(target.lastPathComponent).path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
    }

    func test_validateDeletionPath_rejectsEmptyAndRelativePaths() {
        XCTAssertThrowsError(try policy.validateDeletionPath("")) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .emptyPath)
        }

        XCTAssertThrowsError(try policy.validateDeletionPath("Library/Caches/file")) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .relativePath("Library/Caches/file"))
        }
    }

    func test_validateDeletionPath_rejectsVolumePathOutsideTrash() {
        let path = volumesRoot
            .appendingPathComponent("External/SomeOtherFolder/file.bin")
            .path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
    }

    func test_uniqueValidatedDeletionURLs_deduplicatesCanonicalPaths() throws {
        let file = cacheRoot.appendingPathComponent("com.example/file.bin")
        let duplicate = cacheRoot.appendingPathComponent("com.example/../com.example/file.bin")

        let urls = try policy.uniqueValidatedDeletionURLs(for: [file.path, duplicate.path])

        XCTAssertEqual(urls, [file.standardizedFileURL])
    }
}
