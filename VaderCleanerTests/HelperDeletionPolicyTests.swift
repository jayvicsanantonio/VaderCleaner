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
    private var launchAgentsRoot: URL!
    private var launchDaemonsRoot: URL!
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
        launchAgentsRoot = tempRoot.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        launchDaemonsRoot = tempRoot.appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
        volumesRoot = tempRoot.appendingPathComponent("Volumes", isDirectory: true)

        let roots: [URL] = [
            cacheRoot,
            logsRoot,
            varFoldersRoot,
            applicationsRoot,
            libraryApplicationSupportRoot,
            frameworksRoot,
            launchAgentsRoot,
            launchDaemonsRoot,
            volumesRoot
        ]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        policy = HelperDeletionPolicy(
            allowedDescendantRoots: [
                cacheRoot,
                logsRoot,
                varFoldersRoot
            ],
            allowedLaunchPlistRoots: [
                launchAgentsRoot,
                launchDaemonsRoot
            ],
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

    func test_productionPolicy_acceptsVarFoldersAlias() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/var/folders"))
        let path = "/var/folders/com.example/file.bin"

        XCTAssertEqual(
            try HelperDeletionPolicy.production.validateDeletionPath(path).path,
            URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    func test_validateDeletionPath_acceptsLanguageResourceDirectoryInsideAppBundle() throws {
        let url = applicationsRoot
            .appendingPathComponent("Example.app/Contents/Resources/fr.lproj", isDirectory: true)

        XCTAssertEqual(try policy.validateDeletionPath(url.path).path, url.standardizedFileURL.path)
    }

    func test_validateDeletionPath_acceptsSystemLaunchAgentAndDaemonPlists() throws {
        let agent = launchAgentsRoot.appendingPathComponent("com.example.agent.plist")
        let daemon = launchDaemonsRoot.appendingPathComponent("com.example.daemon.plist")

        XCTAssertEqual(try policy.validateDeletionPath(agent.path), agent.standardizedFileURL)
        XCTAssertEqual(try policy.validateDeletionPath(daemon.path), daemon.standardizedFileURL)
    }

    func test_validateDeletionPath_rejectsNonPlistLaunchItems() {
        let path = launchAgentsRoot.appendingPathComponent("com.example.agent.txt").path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
    }

    func test_validateDeletionPath_rejectsNestedLaunchPlists() {
        let path = launchAgentsRoot.appendingPathComponent("Nested/com.example.agent.plist").path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
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

    func test_validateDeletionPath_acceptsLanguageResourceInsideApplicationSupport() throws {
        let url = libraryApplicationSupportRoot
            .appendingPathComponent("Example/Resources/fr.lproj/Localizable.strings")

        XCTAssertEqual(try policy.validateDeletionPath(url.path), url.standardizedFileURL)
    }

    func test_validateDeletionPath_rejectsLanguageResourceWithoutPackageOutsideApplicationSupport() {
        let path = applicationsRoot
            .appendingPathComponent("Example/Resources/fr.lproj/Localizable.strings")
            .path

        XCTAssertThrowsError(try policy.validateDeletionPath(path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(path))
        }
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

    func test_validateDeletionPath_returnsRequestedSymlinkPathWhenTargetIsAllowed() throws {
        let target = launchDaemonsRoot.appendingPathComponent("com.example.daemon.plist")
        try Data().write(to: target)
        let link = varFoldersRoot.appendingPathComponent("linked-daemon.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(try policy.validateDeletionPath(link.path), link.standardizedFileURL)
    }

    func test_validateDeletionPath_rejectsOutsideSymlinkToAllowedTarget() throws {
        let target = cacheRoot.appendingPathComponent("com.example/file.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: target)
        let outside = tempRoot.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: target)

        XCTAssertThrowsError(try policy.validateDeletionPath(outside.path)) { error in
            XCTAssertEqual(error as? HelperDeletionValidationError, .disallowedPath(outside.path))
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

    func test_removeValidatedPaths_attemptsRemainingURLsAfterFirstRemovalError() throws {
        let first = cacheRoot.appendingPathComponent("com.example/locked.bin")
        let second = cacheRoot.appendingPathComponent("com.example/next.bin")
        var attempted: [URL] = []

        let error = try policy.removeValidatedPaths([first.path, second.path]) { url in
            attempted.append(url)
            if url == first.standardizedFileURL {
                throw NSError(domain: "test.remove", code: 7)
            }
        }
        let nsError = error as NSError?

        XCTAssertEqual(attempted, [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(nsError?.domain, "test.remove")
        XCTAssertEqual(nsError?.code, 7)
    }

    func test_removeValidatedPaths_removesRequestedSymlinkNotResolvedTarget() throws {
        let target = launchDaemonsRoot.appendingPathComponent("com.example.daemon.plist")
        try Data().write(to: target)
        let link = varFoldersRoot.appendingPathComponent("linked-daemon.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var attempted: [URL] = []

        let error = try policy.removeValidatedPaths([link.path]) { url in
            attempted.append(url)
        }

        XCTAssertNil(error)
        XCTAssertEqual(attempted, [link.standardizedFileURL])
    }
}
