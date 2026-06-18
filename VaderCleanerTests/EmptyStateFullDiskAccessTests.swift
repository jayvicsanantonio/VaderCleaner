// EmptyStateFullDiskAccessTests.swift
// Pins that each FDA-sensitive section's empty/clean detail state surfaces the inline Full Disk Access reminder when access is missing, so a user who tapped Scan before reading the intro reminder still sees why the result looks like "nothing found."

import XCTest
@testable import VaderCleaner

@MainActor
final class EmptyStateFullDiskAccessTests: XCTestCase {

    func test_largeOldFilesEmptyState_showsReminderOnlyWhenAccessIsMissing() {
        let missing = LargeOldFilesEmptyState(
            onScanAgain: {},
            hasFullDiskAccess: false,
            onRefreshAccess: {}
        )
        XCTAssertTrue(
            missing.shouldShowFullDiskAccessReminder,
            "The empty state must surface the reminder when Full Disk Access is missing"
        )

        let granted = LargeOldFilesEmptyState(
            onScanAgain: {},
            hasFullDiskAccess: true,
            onRefreshAccess: {}
        )
        XCTAssertFalse(
            granted.shouldShowFullDiskAccessReminder,
            "The empty state must hide the reminder once Full Disk Access is granted"
        )
    }

    func test_systemJunkEmptyPreviewState_showsReminderOnlyWhenAccessIsMissing() {
        let missing = SystemJunkEmptyPreviewState(
            onScanAgain: {},
            hasFullDiskAccess: false,
            onRefreshAccess: {}
        )
        XCTAssertTrue(
            missing.shouldShowFullDiskAccessReminder,
            "The empty preview state must surface the reminder when Full Disk Access is missing"
        )

        let granted = SystemJunkEmptyPreviewState(
            onScanAgain: {},
            hasFullDiskAccess: true,
            onRefreshAccess: {}
        )
        XCTAssertFalse(
            granted.shouldShowFullDiskAccessReminder,
            "The empty preview state must hide the reminder once Full Disk Access is granted"
        )
    }
}
