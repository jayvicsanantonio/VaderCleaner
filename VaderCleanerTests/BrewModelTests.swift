// BrewModelTests.swift
// Verifies the Homebrew value types: id composition across kinds, dependent detection, and Hashable behavior.

import XCTest
@testable import VaderCleaner

final class BrewModelTests: XCTestCase {

    func test_package_idFoldsInKind() {
        let formula = BrewPackage(name: "docker", kind: .formula, installedVersions: ["25.0"], isLeaf: true)
        let cask = BrewPackage(name: "docker", kind: .cask, installedVersions: ["4.27"], isLeaf: true)
        XCTAssertEqual(formula.id, "docker|formula")
        XCTAssertEqual(cask.id, "docker|cask")
        XCTAssertNotEqual(formula.id, cask.id)
    }

    func test_outdatedItem_idFoldsInKind() {
        let item = BrewOutdatedItem(
            name: "git",
            kind: .formula,
            installedVersion: "2.42.0",
            candidateVersion: "2.43.0",
            isPinned: false
        )
        XCTAssertEqual(item.id, "git|formula")
    }

    func test_uninstallConfirmation_detectsBlockingDependents() {
        let target = BrewPackage(name: "openssl@3", kind: .formula, installedVersions: ["3.2.0"], isLeaf: false)
        let blocking = UninstallConfirmation(
            targets: [target],
            dependents: ["openssl@3": ["curl", "wget"]]
        )
        XCTAssertTrue(blocking.hasBlockingDependents)

        let clear = UninstallConfirmation(
            targets: [target],
            dependents: ["openssl@3": []]
        )
        XCTAssertFalse(clear.hasBlockingDependents)
    }

    func test_package_hashableAndEquatable() {
        let a = BrewPackage(name: "git", kind: .formula, installedVersions: ["2.43.0"], isLeaf: true)
        let b = BrewPackage(name: "git", kind: .formula, installedVersions: ["2.43.0"], isLeaf: true)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
