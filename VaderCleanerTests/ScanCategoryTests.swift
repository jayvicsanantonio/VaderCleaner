// ScanCategoryTests.swift
// Tests that every ScanCategory case has a non-empty display name and stable raw value for persistence.

import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

/// Pins the public surface of `ScanCategory`.
///
/// Categories are persisted (e.g. as raw values in user preferences) and
/// surfaced in the UI by `displayName`. A future refactor that drops a case
/// or renames a raw value would silently break stored state — these tests
/// catch that.
@Suite
struct ScanCategoryTests {

    /// `allCases` is the source of truth for the System Junk preview list and
    /// the Large & Old Files scanner's category set. Pinning the count means
    /// any future case addition is a deliberate test update, not a silent
    /// expansion that breaks downstream UI assumptions.
    @Test
    func allCases_containsAllExpectedCategories() {
        #expect(ScanCategory.allCases.count == 13)
        #expect(ScanCategory.allCases.contains(.systemCache))
        #expect(ScanCategory.allCases.contains(.userCache))
        #expect(ScanCategory.allCases.contains(.systemLogs))
        #expect(ScanCategory.allCases.contains(.userLogs))
        #expect(ScanCategory.allCases.contains(.languageFiles))
        #expect(ScanCategory.allCases.contains(.mailAttachments))
        #expect(ScanCategory.allCases.contains(.iosBackups))
        #expect(ScanCategory.allCases.contains(.trash))
        #expect(ScanCategory.allCases.contains(.largeFile))
        #expect(ScanCategory.allCases.contains(.oldFile))
        #expect(ScanCategory.allCases.contains(.xcodeJunk))
        #expect(ScanCategory.allCases.contains(.documentVersions))
        #expect(ScanCategory.allCases.contains(.webDevJunk))
    }

    /// Every case must produce a non-empty user-facing label so the UI never
    /// renders a blank row.
    @Test
    func displayName_nonEmptyForEveryCase() {
        for category in ScanCategory.allCases {
            #expect(!category.displayName.isEmpty, "Display name was empty for \(category)")
        }
    }

    /// `isSafeToAutoRemove` is the single source of truth every cleanup surface
    /// (Smart Scan, standalone Cleanup Manager, My Clutter) consults to seed its
    /// default selection. Safe = regenerable or already-discarded; user-data
    /// categories must stay opt-in.
    @Test
    func isSafeToAutoRemove_pinsTheSafeSet() {
        let safe: Set<ScanCategory> = [
            .systemCache, .userCache,
            .systemLogs, .userLogs,
            .languageFiles,
            .xcodeJunk, .documentVersions, .webDevJunk,
            .trash,
        ]
        for category in ScanCategory.allCases {
            #expect(
                category.isSafeToAutoRemove == safe.contains(category),
                "\(category) safe-to-auto-remove classification is wrong"
            )
        }
    }

    /// The risky categories — real user data that a one-tap clean must never
    /// pre-check — are explicitly opt-in.
    @Test
    func isSafeToAutoRemove_excludesUserDataCategories() {
        for category in [ScanCategory.mailAttachments, .iosBackups, .largeFile, .oldFile] {
            #expect(!category.isSafeToAutoRemove, "\(category) holds user data and must not be auto-removed")
        }
    }

    /// Raw values back persistence (preferences, JSON-encoded scan reports).
    /// Pinning them here guarantees a rename is accompanied by a test update.
    @Test
    func rawValues_areStable() {
        #expect(ScanCategory.systemCache.rawValue == "systemCache")
        #expect(ScanCategory.userCache.rawValue == "userCache")
        #expect(ScanCategory.trash.rawValue == "trash")
        #expect(ScanCategory.largeFile.rawValue == "largeFile")
        #expect(ScanCategory.xcodeJunk.rawValue == "xcodeJunk")
        #expect(ScanCategory.documentVersions.rawValue == "documentVersions")
        #expect(ScanCategory.webDevJunk.rawValue == "webDevJunk")
    }
}
