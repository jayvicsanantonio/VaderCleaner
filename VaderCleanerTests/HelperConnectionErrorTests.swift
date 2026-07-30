// HelperConnectionErrorTests.swift
// Pins the single source of truth for privileged-helper connection failures: the canonical user-facing copy and the error-to-message mapper used by every helper-backed view model.

import XCTest
@testable import VaderCleaner

final class HelperConnectionErrorTests: XCTestCase {

    private let expectedCopy =
        "VaderCleaner Helper is not responding. Try restarting the app."

    func test_unavailable_localizedDescription_isPrescribedCopy() {
        XCTAssertEqual(
            HelperConnectionError.unavailable.errorDescription,
            expectedCopy
        )
        XCTAssertEqual(
            HelperConnectionError.unavailable.localizedDescription,
            expectedCopy
        )
    }

    func test_userFacingMessage_forUnavailable_isPrescribedCopy() {
        XCTAssertEqual(
            HelperConnectionError.userFacingMessage(for: HelperConnectionError.unavailable),
            expectedCopy
        )
    }

    /// NSXPCConnection surfaces a refused or lost connection as
    /// NSCocoaErrorDomain codes 4097 (interrupted), 4099 (invalid), 4101 (reply
    /// invalid), and 4102 (the peer failed our code-signing requirement). All
    /// four must read as the same friendly copy rather than a cryptic system
    /// string ("Couldn't communicate with a helper application.", "The code
    /// signature requirement failed.").
    func test_userFacingMessage_forXPCConnectionErrors_isPrescribedCopy() {
        for code in [4097, 4099, 4101, 4102] {
            let error = NSError(domain: NSCocoaErrorDomain, code: code)
            XCTAssertEqual(
                HelperConnectionError.userFacingMessage(for: error),
                expectedCopy,
                "Expected XPC NSCocoaError \(code) to map to the helper copy"
            )
        }
    }

    /// Unrelated errors must pass through their own localized description so
    /// a locked-file or permission failure still tells the user what happened.
    func test_userFacingMessage_forUnrelatedError_passesThroughDescription() {
        let unrelated = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "You don't have permission."]
        )
        XCTAssertEqual(
            HelperConnectionError.userFacingMessage(for: unrelated),
            "You don't have permission."
        )
    }

    /// `isConnectionFailure` recognises the helper-unavailable sentinel and the
    /// four NSXPC connection-class codes — the signal a caller uses to offer a
    /// "Reinstall Helper" recovery.
    func test_isConnectionFailure_trueForHelperErrorAndXPCConnectionCodes() {
        XCTAssertTrue(HelperConnectionError.isConnectionFailure(HelperConnectionError.unavailable))
        for code in [4097, 4099, 4101, 4102] {
            XCTAssertTrue(
                HelperConnectionError.isConnectionFailure(NSError(domain: NSCocoaErrorDomain, code: code)),
                "Expected XPC NSCocoaError \(code) to count as a connection failure"
            )
        }
    }

    /// A substantive error (e.g. a permission denial) is NOT a connection
    /// failure — reinstalling the helper wouldn't help, so it must read false.
    func test_isConnectionFailure_falseForSubstantiveError() {
        let permission = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertFalse(HelperConnectionError.isConnectionFailure(permission))
        let otherDomain = NSError(domain: "com.example.other", code: 4097)
        XCTAssertFalse(HelperConnectionError.isConnectionFailure(otherDomain),
                       "Connection codes only count in NSCocoaErrorDomain")
    }

    /// A helper that answers but fails the app's code-signing requirement is a
    /// connection failure, not a substantive one: the two ends disagree on
    /// identity, and re-registering the helper is the fix.
    func test_isConnectionFailure_trueForCodeSigningRequirementFailure() {
        let rejected = NSError(
            domain: NSCocoaErrorDomain,
            code: 4102,
            userInfo: [NSLocalizedDescriptionKey: "The code signature requirement failed."]
        )
        XCTAssertTrue(HelperConnectionError.isConnectionFailure(rejected))
    }
}
