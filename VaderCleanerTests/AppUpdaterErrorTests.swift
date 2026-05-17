// AppUpdaterErrorTests.swift
// Pins the App Updater network-failure copy and the error-to-message mapper that rewrites URL-loading failures into a clear, actionable string.

import XCTest
@testable import VaderCleaner

final class AppUpdaterErrorTests: XCTestCase {

    private let expectedCopy =
        "Could not check for updates. Check your internet connection."

    func test_networkUnavailable_localizedDescription_isPrescribedCopy() {
        XCTAssertEqual(
            AppUpdaterError.networkUnavailable.errorDescription,
            expectedCopy
        )
    }

    /// Every offline-class URLError must read as the same friendly copy
    /// rather than Foundation's terser "The Internet connection appears
    /// to be offline." / "A server with the specified hostname could not
    /// be found."
    func test_userFacingMessage_forURLErrors_isPrescribedCopy() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .timedOut,
            .dnsLookupFailed
        ]
        for code in codes {
            XCTAssertEqual(
                AppUpdaterError.userFacingMessage(for: URLError(code)),
                expectedCopy,
                "Expected URLError \(code) to map to the network copy"
            )
        }
    }

    /// An NSURLErrorDomain NSError (the bridged form some callers see)
    /// must also normalize to the network copy.
    func test_userFacingMessage_forNSURLError_isPrescribedCopy() {
        let nsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        )
        XCTAssertEqual(
            AppUpdaterError.userFacingMessage(for: nsError),
            expectedCopy
        )
    }

    /// A non-network error (e.g. a filesystem failure raised by app
    /// discovery) must pass through its own description so the user is
    /// not misdirected toward their network.
    func test_userFacingMessage_forUnrelatedError_passesThroughDescription() {
        let unrelated = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't read the app bundle."]
        )
        XCTAssertEqual(
            AppUpdaterError.userFacingMessage(for: unrelated),
            "Couldn't read the app bundle."
        )
    }
}
