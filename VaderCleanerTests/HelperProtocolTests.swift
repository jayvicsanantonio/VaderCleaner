// HelperProtocolTests.swift
// Tests for the shared XPC helper protocol — selector presence, @objc visibility, and mach service constant.

import XCTest
@testable import VaderCleaner

final class HelperProtocolTests: XCTestCase {

    func test_machServiceName_constant_isCorrect() {
        XCTAssertEqual(kHelperMachServiceName, "com.personal.VaderCleaner.helper")
    }

    func test_releaseCodeSigningRequirement_includesTeamIdentifier() {
        let requirement = HelperCodeSigningRequirements.releaseRequirement(
            identifier: "com.personal.VaderCleaner",
            teamIdentifier: "ABCDE12345"
        )

        XCTAssertEqual(
            requirement,
            "identifier \"com.personal.VaderCleaner\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""
        )
    }

    func test_releaseCodeSigningRequirement_withoutTeamIdentifierRemainsIdentifierOnly() {
        let requirement = HelperCodeSigningRequirements.releaseRequirement(
            identifier: "com.personal.VaderCleaner",
            teamIdentifier: nil
        )

        XCTAssertEqual(requirement, "identifier \"com.personal.VaderCleaner\"")
    }

    func test_debugCodeSigningRequirement_canRemainIdentifierOnly() {
        let requirement = HelperCodeSigningRequirements.requirement(
            identifier: "com.personal.VaderCleaner",
            teamIdentifier: nil
        )

        XCTAssertEqual(requirement, "identifier \"com.personal.VaderCleaner\"")
    }

    func test_placeholderTeamIdentifier_isNotCompiledIntoRequirement() {
        for placeholder in ["TEAMID", "TeamID", "teamid"] {
            let requirement = HelperCodeSigningRequirements.requirement(
                identifier: "com.personal.VaderCleaner",
                teamIdentifier: placeholder
            )

            XCTAssertEqual(requirement, "identifier \"com.personal.VaderCleaner\"")
        }
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
            "flushInactiveMemoryWithReply:",
            "flushDNSCacheWithReply:",
            "reindexSpotlightWithReply:",
            "thinTimeMachineSnapshotsWithReply:",
            "scanDocumentVersionsWithReply:"
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
