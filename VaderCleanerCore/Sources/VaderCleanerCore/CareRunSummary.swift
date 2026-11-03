// CareRunSummary.swift
// What a Fix pass will do, in the results hero's words: one total for everything Fix acts on, split into what is deleted now and what goes to the Trash.

import Foundation

/// The results hero's account of the pending Fix pass. The total is the whole
/// selection Fix acts on — the number each card's selection adds up to — and
/// the split says where it goes, because only what is deleted for good frees
/// space before the Trash is emptied. Stating both keeps the hero, the cards,
/// and the Fix disc's caption on one number instead of three.
public struct CareRunSummary: Equatable, Sendable {

    /// Bytes across every finding a Run would act on.
    public let totalBytes: Int64
    /// The part of `totalBytes` deleted for good rather than moved to the Trash.
    public let deletedBytes: Int64
    /// Findings a Run would act on.
    public let fixCount: Int
    /// Opt-in findings with nothing picked yet — the user's open decisions.
    public let decideCount: Int

    public init(totalBytes: Int64, deletedBytes: Int64, fixCount: Int, decideCount: Int) {
        self.totalBytes = totalBytes
        self.deletedBytes = deletedBytes
        self.fixCount = fixCount
        self.decideCount = decideCount
    }

    /// The part of `totalBytes` that goes to the Trash.
    public var trashedBytes: Int64 {
        max(0, totalBytes - deletedBytes)
    }

    /// The deleted share of the total, for the hero's split bar.
    public var deletedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(deletedBytes) / Double(totalBytes)
    }

    /// The hero's big line: the total Fix will clean, or how many fixes are
    /// ready when none of them is measured in bytes. `nil` when Fix has nothing
    /// to do, so the hero falls back to the verdict.
    public var headline: String? {
        if totalBytes > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%@ ready to clean", bundle: .module, comment: "Results hero headline: total bytes the Fix pass acts on."),
                CareFindingCopy.formattedBytes(totalBytes)
            )
        }
        guard fixCount > 0 else { return nil }
        if fixCount == 1 {
            return String(localized: "1 fix ready", bundle: .module, comment: "Results hero headline: one finding Fix will act on, none measured in bytes.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%d fixes ready", bundle: .module, comment: "Results hero headline: findings Fix will act on, none measured in bytes."),
            fixCount
        )
    }

    /// Where the total goes. Only space deleted for good comes back right
    /// away; the rest waits in the Trash, which is what lets the user undo.
    public var breakdown: String? {
        guard totalBytes > 0 else { return nil }
        if deletedBytes > 0 && trashedBytes > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%@ deleted now · %@ goes to the Trash", bundle: .module, comment: "Results hero breakdown: bytes deleted for good, then bytes moved to the Trash."),
                CareFindingCopy.formattedBytes(deletedBytes),
                CareFindingCopy.formattedBytes(trashedBytes)
            )
        }
        if deletedBytes > 0 {
            return String(
                localized: "All of it is deleted for good — your Mac rebuilds what it needs.",
                bundle: .module,
                comment: "Results hero breakdown when everything Fix cleans bypasses the Trash."
            )
        }
        return String(
            localized: "All of it goes to the Trash, so you can change your mind.",
            bundle: .module,
            comment: "Results hero breakdown when everything Fix cleans goes to the Trash."
        )
    }

    /// The plan in one line: what Fix includes and what is still the user's call.
    public var planLine: String? {
        var parts: [String] = []
        if fixCount > 0 {
            parts.append(String.localizedStringWithFormat(
                String(localized: "%d included in Fix", bundle: .module, comment: "Results hero plan line: findings Fix will act on."),
                fixCount
            ))
        }
        if decideCount > 0 {
            parts.append(String.localizedStringWithFormat(
                String(localized: "%d for you to decide", bundle: .module, comment: "Results hero plan line: opt-in findings with nothing picked yet."),
                decideCount
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
