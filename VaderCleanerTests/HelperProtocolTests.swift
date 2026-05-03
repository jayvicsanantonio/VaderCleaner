// HelperProtocolTests.swift
// Tests for the shared XPC helper protocol — selector presence, @objc visibility, and mach service constant.

import XCTest
@testable import VaderCleaner

final class HelperProtocolTests: XCTestCase {

    func test_machServiceName_constant_isCorrect() {
        XCTAssertEqual(kHelperMachServiceName, "com.personal.VaderCleaner.helper")
    }

    func test_protocol_isVisibleToObjCRuntime() {
        // NSXPCConnection requires @objc protocols. NSProtocolFromString resolves them via the
        // ObjC runtime — a Swift-only protocol would return nil here.
        let proto = NSProtocolFromString("VaderCleanerHelperProtocol")
        XCTAssertNotNil(proto, "VaderCleanerHelperProtocol must be @objc to be usable with NSXPCConnection")
    }

    func test_protocol_hasAllRequiredSelectors() throws {
        let proto = try XCTUnwrap(NSProtocolFromString("VaderCleanerHelperProtocol"))

        let expectedSelectors = [
            "deleteFiles:reply:",
            "runMaintenanceScriptsWithReply:",
            "removeLoginItemAtPath:reply:",
            "removeLaunchAgentAtPath:reply:",
            "flushInactiveMemoryWithReply:"
        ]

        for selectorName in expectedSelectors {
            let selector = NSSelectorFromString(selectorName)
            // protocol_getMethodDescription returns a non-null .name when the selector is required.
            let description = protocol_getMethodDescription(proto, selector, true, true)
            XCTAssertNotNil(
                description.name,
                "Expected protocol to declare selector '\(selectorName)'"
            )
        }
    }
}
