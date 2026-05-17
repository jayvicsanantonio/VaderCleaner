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

    /// NSXPCConnection surfaces connection loss as NSCocoaErrorDomain codes
    /// 4097 (interrupted), 4099 (invalid), 4101 (reply invalid). All three
    /// must read as the same friendly copy rather than the cryptic system
    /// string ("Couldn't communicate with a helper application.").
    func test_userFacingMessage_forXPCConnectionErrors_isPrescribedCopy() {
        for code in [4097, 4099, 4101] {
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
}
