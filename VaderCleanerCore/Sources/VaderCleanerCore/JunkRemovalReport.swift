// JunkRemovalReport.swift
// What a junk clean actually did — bytes gone from the disk, bytes moved to the Trash, what couldn't be removed, and whether it was stopped — so the screen never claims more than happened.

import Foundation

/// The outcome of a junk clean.
///
/// Freed and moved are kept apart because they mean different things to the disk:
/// moving a file to the Trash returns no space until the Trash is emptied, so
/// calling it "freed" promises something that hasn't happened.
public struct JunkRemovalReport: Equatable, Sendable {
    /// Bytes removed outright: items already in a Trash and system files.
    public var bytesFreed: Int64
    /// Bytes now in the Trash, which still occupy the disk.
    public var bytesMovedToTrash: Int64
    /// Items that were removed or moved, including ones with no bytes of their own.
    public var removedCount: Int
    /// Items still in place because removing them failed.
    public var failedCount: Int
    /// Whether the clean was stopped before reaching every item.
    public var wasCancelled: Bool

    public init(
        bytesFreed: Int64 = 0,
        bytesMovedToTrash: Int64 = 0,
        removedCount: Int = 0,
        failedCount: Int = 0,
        wasCancelled: Bool = false
    ) {
        self.bytesFreed = bytesFreed
        self.bytesMovedToTrash = bytesMovedToTrash
        self.removedCount = removedCount
        self.failedCount = failedCount
        self.wasCancelled = wasCancelled
    }

    /// Every byte the clean moved or removed.
    public var totalBytes: Int64 { bytesFreed + bytesMovedToTrash }

    /// Whether every attempt failed: the clean tried and left everything in place.
    /// A file that had already gone isn't an attempt that failed, so a clean of a
    /// stale list doesn't read as an error.
    public var removedNothing: Bool { removedCount == 0 && failedCount > 0 }

    /// The results screen's headline: the bytes returned to the disk if any were,
    /// otherwise where the bytes went, otherwise that nothing changed.
    public var headline: String {
        if bytesFreed > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%@ freed", bundle: .module, comment: "Cleanup result headline; %@ is the size removed from the disk."),
                formattedFileBytes(bytesFreed)
            )
        }
        if bytesMovedToTrash > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%@ moved to the Trash", bundle: .module, comment: "Cleanup result headline when everything went to the Trash; %@ is the size."),
                formattedFileBytes(bytesMovedToTrash)
            )
        }
        return String(localized: "Nothing was removed", bundle: .module, comment: "Cleanup result headline when no items were removed.")
    }

    /// Whatever the headline leaves out: Trash bytes still on the disk, items left
    /// behind, and a clean stopped early.
    public var details: [String] {
        var lines: [String] = []
        if bytesMovedToTrash > 0 {
            lines.append(bytesFreed > 0
                ? String.localizedStringWithFormat(
                    String(
                        localized: "Another %@ moved to the Trash. Empty the Trash to get that space back.",
                        bundle: .module,
                        comment: "Cleanup result detail beside a freed-size headline; %@ is the size moved to the Trash."
                    ),
                    formattedFileBytes(bytesMovedToTrash)
                )
                : String(localized: "Empty the Trash to get that space back.", bundle: .module, comment: "Cleanup result detail when everything went to the Trash."))
        }
        if failedCount == 1 {
            lines.append(String(localized: "1 item couldn't be removed.", bundle: .module, comment: "Cleanup result detail for a single failed item."))
        } else if failedCount > 1 {
            lines.append(String.localizedStringWithFormat(
                String(localized: "%@ items couldn't be removed.", bundle: .module, comment: "Cleanup result detail; %@ is the number of failed items."),
                failedCount.formatted(.number)
            ))
        }
        if wasCancelled {
            lines.append(String(localized: "Cleaning was stopped before it finished.", bundle: .module, comment: "Cleanup result detail after the user stopped a clean."))
        }
        return lines
    }

    /// Whether the clean did all it set out to.
    public var finishedCleanly: Bool { failedCount == 0 && !wasCancelled }
}

/// Thrown when a clean tried to remove items and none of them went.
public enum JunkRemovalError: LocalizedError, Equatable {
    case nothingRemoved(failedCount: Int)

    public var errorDescription: String? {
        String(
            localized: "None of the selected items could be removed. Make sure VaderCleaner has Full Disk Access and its helper is enabled, then try again.",
            bundle: .module,
            comment: "Shown when a Cleanup run tried to remove items and every one of them failed."
        )
    }
}
