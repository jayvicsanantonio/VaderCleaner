// CleanupConfirmation.swift
// The numbers and wording of the dialog shown before a Cleanup removal, split by what can't be recovered, so the question always matches what the removal would really do.

import Foundation

/// What a Cleanup removal is about to do, for its confirmation dialog.
public struct CleanupConfirmation: Equatable, Sendable {
    public let itemCount: Int
    public let totalBytes: Int64
    /// The part of `totalBytes` that can't be recovered afterwards.
    public let permanentBytes: Int64

    /// Categories removed outright rather than moved to the Trash: already in a
    /// Trash, or root-owned and so out of reach of the user's Trash. Language
    /// files in `~/Applications` do go to the Trash; counting them here can only
    /// overstate the warning, never understate it.
    private static let permanentCategories: Set<ScanCategory> = [
        .trash, .systemCache, .systemLogs, .languageFiles, .documentVersions,
    ]

    public init(itemCount: Int, totalBytes: Int64, permanentBytes: Int64) {
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.permanentBytes = permanentBytes
    }

    /// Builds the summary from per-category tallies of what would be removed.
    init(bytesByCategory: [ScanCategory: Int64], countByCategory: [ScanCategory: Int]) {
        self.init(
            itemCount: countByCategory.values.reduce(0, +),
            totalBytes: bytesByCategory.values.reduce(0, +),
            permanentBytes: bytesByCategory.reduce(0) { sum, entry in
                Self.permanentCategories.contains(entry.key) ? sum + entry.value : sum
            }
        )
    }

    public var title: String {
        String.localizedStringWithFormat(
            String(
                localized: "Remove %@ of junk?",
                bundle: .module,
                comment: "Title of the Cleanup confirmation dialog; %@ is the total size."
            ),
            formattedFileBytes(totalBytes)
        )
    }

    public var message: String {
        let items = itemCount.formatted(.number)
        if permanentBytes >= totalBytes {
            return String.localizedStringWithFormat(
                String(
                    localized: "All %@ selected items will be deleted permanently. You can't undo this.",
                    bundle: .module,
                    comment: "Cleanup confirmation when everything selected is deleted outright; %@ is the item count."
                ),
                items
            )
        }
        if permanentBytes > 0 {
            return String.localizedStringWithFormat(
                String(
                    localized: "%1$@ will be deleted permanently, which you can't undo. The other %2$@ moves to the Trash and returns no space until the Trash is emptied.",
                    bundle: .module,
                    comment: "Cleanup confirmation when part of the selection is deleted outright; %1$@ is the permanent size, %2$@ the size going to the Trash."
                ),
                formattedFileBytes(permanentBytes),
                formattedFileBytes(totalBytes - permanentBytes)
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "All %@ selected items move to the Trash, where you can still recover them. The space returns once the Trash is emptied.",
                bundle: .module,
                comment: "Cleanup confirmation when everything selected goes to the Trash; %@ is the item count."
            ),
            items
        )
    }
}
