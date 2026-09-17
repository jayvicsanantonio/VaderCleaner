// PermissionOnboardingViewModelTests.swift
// Tests that PermissionOnboardingViewModel exposes the expected dismissal state and System Settings URL.

import XCTest
@testable import VaderCleaner

@MainActor
final class PermissionOnboardingViewModelTests: XCTestCase {

    func test_isDismissed_defaultsToFalse() {
        let sut = PermissionOnboardingViewModel(openSystemSettings: {})
        XCTAssertFalse(sut.isDismissed)
    }

    func test_dismiss_setsIsDismissedToTrue() {
        let sut = PermissionOnboardingViewModel(openSystemSettings: {})
        sut.dismiss()
        XCTAssertTrue(sut.isDismissed)
    }

    func test_systemSettingsURL_pointsToFullDiskAccessPane() {
        // Asserts the URL constant — calling NSWorkspace.shared.open in tests would
        // actually launch System Settings, so the test exercises the URL only.
        XCTAssertEqual(
            PermissionOnboardingViewModel.systemSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.Settings.PrivacyAndSecurity.extension?Privacy_AllFiles"
        )
    }

    func test_openSystemSettings_invokesTheInjectedAction() {
        let opened = TestBox(0)
        let sut = PermissionOnboardingViewModel(openSystemSettings: { opened.value += 1 })
        sut.openSystemSettings()
        XCTAssertEqual(opened.value, 1)
    }

    func test_openSystemSettings_remembersThatTheUserWentToSettings() {
        // Drives the "still seeing this?" note. Without it, the sheet keeps
        // telling the user to click Check Again with no explanation of why
        // that alone won't detect a grant made while VaderCleaner was already
        // running.
        let sut = PermissionOnboardingViewModel(openSystemSettings: {})
        XCTAssertFalse(sut.hasVisitedSystemSettings)
        sut.openSystemSettings()
        XCTAssertTrue(sut.hasVisitedSystemSettings)
    }
}
