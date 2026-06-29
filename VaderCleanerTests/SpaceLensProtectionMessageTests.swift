// SpaceLensProtectionMessageTests.swift
// Verifies the tooltip copy the Space Lens list shows for a protected item's "i" badge.

import XCTest
@testable import VaderCleaner

final class SpaceLensProtectionMessageTests: XCTestCase {

    private func node(_ url: URL) -> DiskNode {
        DiskNode(url: url, name: url.lastPathComponent, size: 0, isDirectory: true, children: [])
    }

    func test_systemFolder_usesEssentialSystemMessage() {
        let message = SpaceLensListPanel.protectionMessage(for: node(URL(fileURLWithPath: "/System")))
        XCTAssertEqual(message, "This is an essential system item and it cannot be deleted.")
    }

    func test_homeFolder_usesHomeMessage() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let message = SpaceLensListPanel.protectionMessage(for: node(home))
        XCTAssertEqual(message, "This is your home folder and it can't be removed here.")
    }
}
