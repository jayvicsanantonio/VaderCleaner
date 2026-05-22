// ScanAccessPopoverTests.swift
// Pins the Scan-tap Full Disk Access gate: which sections raise the access popover, and the ScanAccessPopover view's accent + callback contract.

import XCTest
import SwiftUI
@testable import VaderCleaner

@MainActor
final class ScanAccessPopoverTests: XCTestCase {

    // MARK: ScanTapOutcome.evaluate

    func test_evaluate_requiresFDAWithoutAccess_promptsForAccess() {
        XCTAssertEqual(
            ScanTapOutcome.evaluate(requiresFullDiskAccess: true, hasFullDiskAccess: false),
            .promptForFullDiskAccess,
            "An FDA-sensitive section with access missing must hold the scan and prompt"
        )
    }

    func test_evaluate_requiresFDAWithAccess_beginsScan() {
        XCTAssertEqual(
            ScanTapOutcome.evaluate(requiresFullDiskAccess: true, hasFullDiskAccess: true),
            .beginScan,
            "Once Full Disk Access is granted the scan must start straight away"
        )
    }

    func test_evaluate_noFDARequirement_alwaysBeginsScan() {
        // Sections whose scans don't read FDA-protected paths never gate,
        // regardless of the current access state.
        XCTAssertEqual(
            ScanTapOutcome.evaluate(requiresFullDiskAccess: false, hasFullDiskAccess: false),
            .beginScan,
            "A section that doesn't require FDA must scan even when access is missing"
        )
        XCTAssertEqual(
            ScanTapOutcome.evaluate(requiresFullDiskAccess: false, hasFullDiskAccess: true),
            .beginScan,
            "A section that doesn't require FDA must scan when access is present"
        )
    }

    func test_evaluate_acrossEveryScannableSection() {
        // The gate only ever fires for sections that genuinely require FDA,
        // and only while access is missing — pinned against the real
        // NavigationSection metadata so a reclassification can't slip past.
        for section in NavigationSection.allCases where section.isScannable {
            let missing = ScanTapOutcome.evaluate(
                requiresFullDiskAccess: section.requiresFullDiskAccess,
                hasFullDiskAccess: false
            )
            let granted = ScanTapOutcome.evaluate(
                requiresFullDiskAccess: section.requiresFullDiskAccess,
                hasFullDiskAccess: true
            )

            if section.requiresFullDiskAccess {
                XCTAssertEqual(missing, .promptForFullDiskAccess,
                               "\(section) requires FDA — a Scan tap must prompt when access is missing")
            } else {
                XCTAssertEqual(missing, .beginScan,
                               "\(section) does not require FDA — a Scan tap must never prompt")
            }
            XCTAssertEqual(granted, .beginScan,
                           "\(section) must scan immediately once access is granted")
        }
    }

    // MARK: ScanAccessPopover

    func test_defaultAccentIsVaderCrimson() {
        // Unspecified call sites stay on the Vader palette, matching the
        // FloatingScanButton / FullDiskAccessPromptCard defaults.
        let popover = ScanAccessPopover(onOpenSettings: {}, onScanAnyway: {})

        XCTAssertEqual(
            popover.accent,
            .vaderCrimson,
            "ScanAccessPopover must default its tint to VaderTheme crimson"
        )
    }

    func test_customAccentIsStored() {
        let popover = ScanAccessPopover(accent: .green, onOpenSettings: {}, onScanAnyway: {})

        XCTAssertEqual(
            popover.accent,
            .green,
            "A caller-supplied accent must override the crimson default"
        )
    }

    func test_invokesOpenSettingsCallback() {
        var fired = false
        let popover = ScanAccessPopover(onOpenSettings: { fired = true }, onScanAnyway: {})

        XCTAssertFalse(fired, "Callback must not fire on construction")
        popover.onOpenSettings()
        XCTAssertTrue(fired, "Triggering Open System Settings must invoke the supplied callback")
    }

    func test_invokesScanAnywayCallback() {
        var fired = false
        let popover = ScanAccessPopover(onOpenSettings: {}, onScanAnyway: { fired = true })

        XCTAssertFalse(fired, "Callback must not fire on construction")
        popover.onScanAnyway()
        XCTAssertTrue(fired, "Triggering Scan Anyway must invoke the supplied callback")
    }
}
