// SpaceLensProtectionTests.swift
// Verifies which Space Lens locations are protected from removal and the display category each maps to.

import XCTest
@testable import VaderCleaner

final class SpaceLensProtectionTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/vader")

    private func category(_ path: String, isDirectory: Bool = true) -> SpaceLensProtection.Category {
        SpaceLensProtection.category(
            url: URL(fileURLWithPath: path),
            isDirectory: isDirectory,
            homeDirectory: home
        )
    }

    private func isProtected(_ path: String, isDirectory: Bool = true) -> Bool {
        SpaceLensProtection.isProtected(
            url: URL(fileURLWithPath: path),
            isDirectory: isDirectory,
            homeDirectory: home
        )
    }

    func test_homeDirectoryItself_isProtectedHomeFolder() {
        XCTAssertEqual(category("/Users/vader"), .homeFolder)
        XCTAssertTrue(isProtected("/Users/vader"))
    }

    func test_systemRoots_areProtectedSystemFolders() {
        for path in ["/System", "/System/Library/Caches", "/Library", "/usr/bin", "/private/var"] {
            XCTAssertEqual(category(path), .systemFolder, "\(path)")
            XCTAssertTrue(isProtected(path), "\(path)")
        }
    }

    func test_volumeRoot_isProtected() {
        XCTAssertEqual(category("/"), .systemFolder)
        XCTAssertTrue(isProtected("/"))
    }

    func test_usersShared_isProtected() {
        XCTAssertTrue(isProtected("/Users/Shared"))
    }

    /// `/Users` itself is a protected system container (shown with an "i" badge),
    /// but the accounts inside it stay removable.
    func test_usersContainer_isProtectedButAccountsAreNot() {
        XCTAssertTrue(isProtected("/Users"))
        XCTAssertEqual(category("/Users"), .systemFolder)
        XCTAssertFalse(isProtected("/Users/thepinoydev"))
    }

    func test_managedHomeFolders_areProtected() {
        XCTAssertTrue(isProtected("/Users/vader/Library"))
        XCTAssertTrue(isProtected("/Users/vader/Documents"))
        XCTAssertEqual(category("/Users/vader/Documents"), .systemFolder)
    }

    func test_customHomeFolders_areNotProtected() {
        XCTAssertFalse(isProtected("/Users/vader/Videos"))
        XCTAssertFalse(isProtected("/Users/vader/Developer"))
        XCTAssertEqual(category("/Users/vader/Videos"), .folder)
    }

    func test_contentsOfManagedFolder_areNotProtected() {
        // Only the top-level managed folder is locked, not what's inside it.
        XCTAssertFalse(isProtected("/Users/vader/Documents/notes.txt", isDirectory: false))
    }

    func test_otherUserAccount_isNotProtected() {
        XCTAssertFalse(isProtected("/Users/thepinoydev"))
        XCTAssertEqual(category("/Users/thepinoydev"), .folder)
    }

    func test_regularFile_isFileCategory() {
        XCTAssertEqual(category("/Users/vader/Videos/clip.mov", isDirectory: false), .file)
        XCTAssertFalse(isProtected("/Users/vader/Videos/clip.mov", isDirectory: false))
    }
}
