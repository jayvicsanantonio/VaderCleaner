// ProtectionManagerCopyTests.swift
// Pins the Protection screens' counted labels, so a count of one reads in the singular.

import Testing
@testable import VaderCleaner

@Suite
struct ProtectionManagerCopyTests {

    @Test
    func labelsUseTheSingularForOne() {
        #expect(ProtectionCopy.items(1) == "1 item")
        #expect(ProtectionCopy.threatsFound(1) == "1 Threat Found")
        #expect(ProtectionCopy.threatsRemoved(1) == "1 Threat Removed")
        #expect(ProtectionCopy.threatsSelected(1) == "1 Threat Selected")
        #expect(ProtectionCopy.privacyItemsSelected(1) == "1 Privacy Item Selected")
    }

    @Test
    func labelsUseThePluralForMany() {
        #expect(ProtectionCopy.items(2) == "2 items")
        #expect(ProtectionCopy.threatsFound(2) == "2 Threats Found")
        #expect(ProtectionCopy.threatsRemoved(2) == "2 Threats Removed")
        #expect(ProtectionCopy.threatsSelected(2) == "2 Threats Selected")
        #expect(ProtectionCopy.privacyItemsSelected(2) == "2 Privacy Items Selected")
    }
}
