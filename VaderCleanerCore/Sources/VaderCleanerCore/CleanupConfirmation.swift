// CleanupConfirmation.swift
// The numbers and wording of the dialog shown before a Cleanup removal, split by what can't be recovered, so the question always matches what the removal would really do.

import Foundation

/// What a Cleanup removal is about to do, for its confirmation dialog.
public struct CleanupConfirmation: Equatable, Sendable {
    public let itemCount: Int
    /// How many of those items can't be recovered afterwards. The wording goes by
    /// this rather than by bytes, because an empty file has no bytes but still
    /// goes one way or the other.
    public let permanentItemCount: Int
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

    public init(itemCount: Int, permanentItemCount: Int, totalBytes: Int64, permanentBytes: Int64) {
        self.itemCount = itemCount
        self.permanentItemCount = permanentItemCount
        self.totalBytes = totalBytes
        self.permanentBytes = permanentBytes
    }

    /// Builds the summary from per-category tallies of what would be removed.
    init(bytesByCategory: [ScanCategory: Int64], countByCategory: [ScanCategory: Int]) {
        self.init(
            itemCount: countByCategory.values.reduce(0, +),
            permanentItemCount: countByCategory.reduce(0) { sum, entry in
                Self.permanentCategories.contains(entry.key) ? sum + entry.value : sum
            },
            totalBytes: bytesByCategory.values.reduce(0, +),
            permanentBytes: bytesByCategory.reduce(0) { sum, entry in
                Self.permanentCategories.contains(entry.key) ? sum + entry.value : sum
            }
        )
    }

    public var title: String {
        String.localizedStringWithFormat(
            String(
                localized: "Remove %@?",
                bundle: .module,
                comment: "Title of the Cleanup confirmation dialog; %@ is the size, or the item count when there are no bytes."
            ),
            totalBytes > 0 ? formattedFileBytes(totalBytes) : Self.items(itemCount)
        )
    }

    public var message: String {
        if permanentItemCount >= itemCount {
            return String.localizedStringWithFormat(
                String(
                    localized: "%@ will be deleted permanently. You can't undo this.",
                    bundle: .module,
                    comment: "Cleanup confirmation when everything selected is deleted outright; %@ is like \"3 items\"."
                ),
                Self.items(itemCount)
            )
        }
        if permanentItemCount > 0 {
            return String.localizedStringWithFormat(
                String(
                    localized: "%1$@ (%2$@) will be deleted permanently, which you can't undo. The other %3$@ (%4$@) will move to the Trash and return no space until the Trash is emptied.",
                    bundle: .module,
                    comment: "Cleanup confirmation when part of the selection is deleted outright; %1$@ and %3$@ are like \"3 items\", %2$@ and %4$@ are their sizes."
                ),
                Self.items(permanentItemCount),
                formattedFileBytes(permanentBytes),
                Self.items(itemCount - permanentItemCount),
                formattedFileBytes(totalBytes - permanentBytes)
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "%@ will move to the Trash and can still be recovered. The space returns once the Trash is emptied.",
                bundle: .module,
                comment: "Cleanup confirmation when everything selected goes to the Trash; %@ is like \"3 items\"."
            ),
            Self.items(itemCount)
        )
    }

    private static func items(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 item", bundle: .module, comment: "A single item in a Cleanup confirmation.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%@ items", bundle: .module, comment: "An item count in a Cleanup confirmation."),
            count.formatted(.number)
        )
    }
}
