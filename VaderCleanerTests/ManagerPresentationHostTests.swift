// ManagerPresentationHostTests.swift
// Verifies the dashboard↔manager exchange host's keep-alive and motion decisions: when the manager subtree stays mounted after Back, and how the hidden manager mirrors the zoom transition's endpoint.

import XCTest
@testable import VaderCleaner

final class ManagerPresentationHostTests: XCTestCase {

    /// The manager mounts while presented, stays mounted (hidden) once it has
    /// been opened, and is never built before its first open — preserving the
    /// lazy first-open cost while making every reopen instant.
    func test_mountsManager_keepsSubtreeAliveAfterFirstOpen() {
        XCTAssertTrue(ManagerPresentationMotion.mountsManager(isPresented: true, hasOpened: false))
        XCTAssertTrue(ManagerPresentationMotion.mountsManager(isPresented: true, hasOpened: true))
        XCTAssertTrue(ManagerPresentationMotion.mountsManager(isPresented: false, hasOpened: true))
        XCTAssertFalse(ManagerPresentationMotion.mountsManager(isPresented: false, hasOpened: false))
    }

    /// The hidden manager parks at the zoom transition's hidden endpoint (90%),
    /// so Back reads identically to the removal transition it replaces; Reduce
    /// Motion pins the scale and lets opacity carry the exchange.
    func test_managerScale_mirrorsZoomTransitionEndpoints() {
        XCTAssertEqual(ManagerPresentationMotion.managerScale(isPresented: true, reduceMotion: false), 1)
        XCTAssertEqual(ManagerPresentationMotion.managerScale(isPresented: false, reduceMotion: false), 0.9)
        XCTAssertEqual(ManagerPresentationMotion.managerScale(isPresented: true, reduceMotion: true), 1)
        XCTAssertEqual(ManagerPresentationMotion.managerScale(isPresented: false, reduceMotion: true), 1)
    }
}
