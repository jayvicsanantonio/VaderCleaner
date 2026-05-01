// TestHelpersTests.swift
// Tests that verify the TestHelpers utilities behave correctly.

import XCTest
@testable import VaderCleaner

final class TestHelpersTests: XCTestCase {

    // MARK: - createTempDirectory

    func test_createTempDirectory_returnsValidURL() throws {
        let url = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(url) }

        XCTAssertTrue(url.isFileURL, "Expected a file URL")
    }

    func test_createTempDirectory_createsDirectory() throws {
        let url = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(url) }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists, "Expected directory to exist on disk")
        XCTAssertTrue(isDirectory.boolValue, "Expected path to be a directory")
    }

    func test_createTempDirectory_createsUniqueDirectories() throws {
        let url1 = try TestHelpers.createTempDirectory()
        let url2 = try TestHelpers.createTempDirectory()
        defer {
            TestHelpers.tearDownTempDirectory(url1)
            TestHelpers.tearDownTempDirectory(url2)
        }

        XCTAssertNotEqual(url1, url2, "Expected each call to produce a unique directory")
    }

    func test_createTempDirectory_isWritable() throws {
        let url = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(url) }

        XCTAssertTrue(
            FileManager.default.isWritableFile(atPath: url.path),
            "Expected temp directory to be writable"
        )
    }

    // MARK: - tearDownTempDirectory

    func test_tearDownTempDirectory_removesDirectory() throws {
        let url = try TestHelpers.createTempDirectory()
        TestHelpers.tearDownTempDirectory(url)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Expected directory to be removed after teardown"
        )
    }

    func test_tearDownTempDirectory_doesNotThrowForNonexistentPath() {
        let nonexistent = URL(fileURLWithPath: "/tmp/this_does_not_exist_\(UUID().uuidString)")
        // Should not crash or throw
        TestHelpers.tearDownTempDirectory(nonexistent)
    }

    // MARK: - createDummyFiles

    func test_createDummyFiles_createsCorrectCount() throws {
        let dir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(dir) }

        let files = try TestHelpers.createDummyFiles(count: 5, size: 1024, in: dir)

        XCTAssertEqual(files.count, 5, "Expected 5 files to be created")
    }

    func test_createDummyFiles_allFilesExistOnDisk() throws {
        let dir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(dir) }

        let files = try TestHelpers.createDummyFiles(count: 3, size: 512, in: dir)

        for file in files {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "Expected file to exist: \(file.lastPathComponent)"
            )
        }
    }

    func test_createDummyFiles_filesHaveCorrectSize() throws {
        let dir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(dir) }

        let expectedSize = 2048
        let files = try TestHelpers.createDummyFiles(count: 2, size: expectedSize, in: dir)

        for file in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let actualSize = attrs[.size] as? Int ?? 0
            XCTAssertEqual(actualSize, expectedSize, "Expected file size \(expectedSize), got \(actualSize)")
        }
    }

    func test_createDummyFiles_returnsZeroForZeroCount() throws {
        let dir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(dir) }

        let files = try TestHelpers.createDummyFiles(count: 0, size: 100, in: dir)

        XCTAssertTrue(files.isEmpty, "Expected no files for count=0")
    }

    // MARK: - createDummyFile (named)

    func test_createDummyFile_createsFileWithCorrectName() throws {
        let dir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(dir) }

        let file = try TestHelpers.createDummyFile(named: "test.cache", size: 100, in: dir)

        XCTAssertEqual(file.lastPathComponent, "test.cache")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_createDummyFile_createsFileWithCorrectSize() throws {
        let dir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(dir) }

        let expectedSize = 4096
        let file = try TestHelpers.createDummyFile(named: "big.bin", size: expectedSize, in: dir)

        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let actualSize = attrs[.size] as? Int ?? 0
        XCTAssertEqual(actualSize, expectedSize)
    }

    // MARK: - createNestedDirectories

    func test_createNestedDirectories_createsCorrectDepth() throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }

        let deepest = try TestHelpers.createNestedDirectories(depth: 3, in: root)

        // Path should contain level_0/level_1/level_2
        XCTAssertTrue(deepest.path.contains("level_2"), "Expected path to contain level_2")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: deepest.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func test_createNestedDirectories_depthZeroReturnsRoot() throws {
        let root = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(root) }

        let result = try TestHelpers.createNestedDirectories(depth: 0, in: root)

        XCTAssertEqual(result, root, "Expected depth=0 to return the root directory unchanged")
    }
}
