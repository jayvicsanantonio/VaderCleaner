// FileCategoryTests.swift
// Verifies FileCategory's mapping from DiskNode to one of documents/media/apps/system/other based on extension and path heuristics.

import XCTest
@testable import VaderCleaner

/// Unit tests for `FileCategory`. The category drives tile color in the
/// Space Lens treemap, so misclassifications would surface as misleading
/// visual cues. Each branch (extension-driven, `.app` bundle, system path,
/// fallback) is tested in isolation.
final class FileCategoryTests: XCTestCase {

    // MARK: - Documents

    func test_category_documentsForCommonOfficeExtensions() {
        for ext in ["pdf", "doc", "docx", "txt", "rtf", "pages",
                    "xls", "xlsx", "numbers", "ppt", "pptx", "key",
                    "md", "csv"] {
            let node = makeFile(name: "report.\(ext)")
            XCTAssertEqual(FileCategory.from(node: node), .documents,
                           "Expected .documents for .\(ext)")
        }
    }

    // MARK: - Media

    func test_category_mediaForImagesAudioAndVideo() {
        for ext in ["jpg", "jpeg", "png", "gif", "tiff", "heic",
                    "mp4", "mov", "avi", "mkv", "m4v",
                    "mp3", "wav", "aac", "flac", "m4a"] {
            let node = makeFile(name: "asset.\(ext)")
            XCTAssertEqual(FileCategory.from(node: node), .media,
                           "Expected .media for .\(ext)")
        }
    }

    // MARK: - Apps

    /// `.app` bundles read as directories on disk, so the categorizer must
    /// look at the URL extension rather than `isDirectory` alone.
    func test_category_appsForDotAppBundle() {
        let node = makeDirectory(path: "/Applications/Pages.app")
        XCTAssertEqual(FileCategory.from(node: node), .apps)
    }

    // MARK: - System

    func test_category_systemForLibrarySubpaths() {
        let node = makeDirectory(path: "/Users/example/Library/Caches/com.example")
        XCTAssertEqual(FileCategory.from(node: node), .system)
    }

    /// The `~/Library` directory itself (without trailing slash / children
    /// in the path) is the top-level system bucket users actually see in a
    /// home-directory Space Lens scan. Locks the path-component matching
    /// against a previous substring rule that missed the bare directory.
    func test_category_systemForLibraryDirectoryItself() {
        XCTAssertEqual(FileCategory.from(node: makeDirectory(path: "/Library")), .system)
        XCTAssertEqual(FileCategory.from(node: makeDirectory(path: "/Users/example/Library")), .system)
    }

    func test_category_systemForSystemAndPrivatePaths() {
        XCTAssertEqual(FileCategory.from(node: makeDirectory(path: "/System/Library")), .system)
        XCTAssertEqual(FileCategory.from(node: makeDirectory(path: "/private/var/log")), .system)
        XCTAssertEqual(FileCategory.from(node: makeDirectory(path: "/usr/local/bin")), .system)
    }

    /// Path-prefix matching would misclassify these as `.system`. The
    /// component-aware implementation must not. Regression guard against
    /// reintroducing `hasPrefix("/usr")` / `contains("/Library/")` style
    /// rules that match substrings inside legitimate user paths.
    func test_category_otherForPathBoundaryFalsePositives() {
        // `/Users/example/usr_data` — `hasPrefix("/usr")` would have to
        // not match because the path doesn't start with `/usr`, but a
        // careless rule that checks `path.contains("usr")` would.
        let usrLike = makeDirectory(path: "/Users/example/usr_data")
        XCTAssertEqual(FileCategory.from(node: usrLike), .other)

        // `/Users/example/Projects/LibraryNotes` — the literal substring
        // "Library" appears, but as part of "LibraryNotes", not as a
        // path component. Component-aware matching must reject it.
        let libraryLike = makeDirectory(path: "/Users/example/Projects/LibraryNotes")
        XCTAssertEqual(FileCategory.from(node: libraryLike), .other)

        // A user-managed folder literally named "Library" inside a deep
        // Projects tree shouldn't read as system either — only the
        // canonical `~/Library` and `/Library` shapes do.
        let deepLibrary = makeDirectory(path: "/Users/example/Projects/Library")
        XCTAssertEqual(FileCategory.from(node: deepLibrary), .other)
    }

    func test_category_systemForLowLevelExecutableExtensions() {
        for ext in ["dylib", "framework", "kext", "plist", "log"] {
            let node = makeFile(name: "thing.\(ext)")
            XCTAssertEqual(FileCategory.from(node: node), .system,
                           "Expected .system for .\(ext)")
        }
    }

    // MARK: - Other

    func test_category_otherFallback() {
        let unknown = makeFile(name: "weirdfile.xyz")
        XCTAssertEqual(FileCategory.from(node: unknown), .other)

        let extensionless = makeFile(name: "Makefile")
        XCTAssertEqual(FileCategory.from(node: extensionless), .other)
    }

    func test_category_otherForUserDirectoryWithNoSpecialMarker() {
        let node = makeDirectory(path: "/Users/example/Projects")
        XCTAssertEqual(FileCategory.from(node: node), .other)
    }

    // MARK: - Fixtures

    private func makeFile(name: String) -> DiskNode {
        DiskNode(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            size: 1024,
            isDirectory: false,
            children: []
        )
    }

    private func makeDirectory(path: String) -> DiskNode {
        let url = URL(fileURLWithPath: path)
        return DiskNode(
            url: url,
            name: url.lastPathComponent,
            size: 0,
            isDirectory: true,
            children: []
        )
    }
}
