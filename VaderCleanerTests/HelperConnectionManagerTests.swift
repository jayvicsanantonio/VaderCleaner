// HelperConnectionManagerTests.swift
// Tests that HelperConnectionManager builds an NSXPCConnection wired to the shared mach service name and protocol.

import XCTest
@testable import VaderCleaner

final class HelperConnectionManagerTests: XCTestCase {

    func test_singleton_isSameInstance() {
        let first = HelperConnectionManager.shared
        let second = HelperConnectionManager.shared
        XCTAssertTrue(first === second, "HelperConnectionManager.shared must return a single instance")
    }

    func test_connect_returnsConnection_withMatchingMachServiceName() {
        let manager = HelperConnectionManager.shared
        let connection = manager.connect()
        addTeardownBlock { manager.invalidate() }
        XCTAssertEqual(
            connection.serviceName,
            kHelperMachServiceName,
            "Connection must use the shared mach service name constant"
        )
    }

    func test_connect_isIdempotent() {
        let manager = HelperConnectionManager.shared
        addTeardownBlock { manager.invalidate() }
        let first = manager.connect()
        let second = manager.connect()
        XCTAssertTrue(first === second, "connect() must reuse the existing connection until invalidated")
    }

    func test_connect_setsRemoteObjectInterface_toHelperProtocol() {
        let manager = HelperConnectionManager.shared
        let connection = manager.connect()
        addTeardownBlock { manager.invalidate() }
        let proto = NSProtocolFromString("VaderCleanerHelperProtocol")
        XCTAssertNotNil(connection.remoteObjectInterface, "remoteObjectInterface must be set before XPC use")
        XCTAssertTrue(
            connection.remoteObjectInterface?.protocol === proto,
            "remoteObjectInterface must wrap VaderCleanerHelperProtocol"
        )
    }

    func test_invalidate_clearsCachedConnection() {
        let manager = HelperConnectionManager.shared
        let first = manager.connect()
        manager.invalidate()
        let second = manager.connect()
        addTeardownBlock { manager.invalidate() }
        XCTAssertFalse(first === second, "After invalidate(), connect() must return a new connection")
    }
}
