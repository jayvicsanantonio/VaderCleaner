// PermissionOnboardingViewModelTests.swift
// Tests that PermissionOnboardingViewModel exposes the expected dismissal state and System Settings URL.

import XCTest
@testable import VaderCleaner

final class PermissionOnboardingViewModelTests: XCTestCase {

    func test_isDismissed_defaultsToFalse() {
        let sut = PermissionOnboardingViewModel()
        XCTAssertFalse(sut.isDismissed)
    }

    func test_dismiss_setsIsDismissedToTrue() {
        let sut = PermissionOnboardingViewModel()
        sut.dismiss()
        XCTAssertTrue(sut.isDismissed)
    }

    func test_systemSettingsURL_pointsToFullDiskAccessPane() {
        // Asserts the URL constant — calling NSWorkspace.shared.open in tests would
        // actually launch System Settings, so the test exercises the URL only.
        XCTAssertEqual(
            PermissionOnboardingViewModel.systemSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
