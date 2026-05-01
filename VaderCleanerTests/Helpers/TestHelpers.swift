// TestHelpers.swift
// Shared test utilities for creating and tearing down temporary directories and dummy files.

import Foundation
import XCTest

/// Utilities used across all VaderCleaner test targets to set up and tear down
/// isolated temporary file system environments.
enum TestHelpers {

    // MARK: - Temporary Directory Management

    /// Creates a unique temporary directory under the system temp directory.
    /// - Returns: URL of the newly created directory.
    /// - Throws: If the directory cannot be created.
    static func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaderCleanerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return tempDir
    }

    /// Removes the given temporary directory and all its contents.
    /// Silently ignores errors so test teardown never masks real failures.
    /// - Parameter url: URL of the temporary directory to remove.
    static func tearDownTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Dummy File Creation

    /// Creates a specified number of dummy files of a given size inside a directory.
    /// - Parameters:
    ///   - count: Number of files to create.
    ///   - size: Size of each file in bytes.
    ///   - directory: The directory in which to create the files.
    /// - Returns: Array of URLs of the created files.
    /// - Throws: If any file cannot be created.
    @discardableResult
    static func createDummyFiles(count: Int, size: Int, in directory: URL) throws -> [URL] {
        var urls: [URL] = []
        let data = Data(repeating: 0xAB, count: size)
        for index in 0..<count {
            let fileURL = directory.appendingPathComponent("dummy_\(index).bin")
            try data.write(to: fileURL)
            urls.append(fileURL)
        }
        return urls
    }

    /// Creates a dummy file with a specific name and size inside a directory.
    /// - Parameters:
    ///   - name: File name (including extension).
    ///   - size: Size in bytes.
    ///   - directory: The directory in which to create the file.
    /// - Returns: URL of the created file.
    /// - Throws: If the file cannot be created.
    @discardableResult
    static func createDummyFile(named name: String, size: Int, in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent(name)
        let data = Data(repeating: 0xCD, count: size)
        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates a nested subdirectory structure for testing directory traversal.
    /// - Parameters:
    ///   - depth: Number of nested subdirectory levels to create.
    ///   - root: The root directory to nest inside.
    /// - Returns: URL of the deepest created directory.
    /// - Throws: If any directory cannot be created.
    @discardableResult
    static func createNestedDirectories(depth: Int, in root: URL) throws -> URL {
        var current = root
        for level in 0..<depth {
            current = current.appendingPathComponent("level_\(level)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: current,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        return current
    }
}
