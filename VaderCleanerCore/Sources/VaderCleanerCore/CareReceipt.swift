// CareReceipt.swift
// The readable record of one Run pass: per-finding outcome lines with items processed, bytes freed, and bytes moved to the Trash. Codable so scan history can persist receipts.

import Foundation

/// One line of the receipt: what Run did about one finding. `kind` keys the
/// plain-language copy; the outcome distinguishes clean success from partial
/// work and honest failure so nothing is silently glossed over.
public struct CareReceiptLine: Equatable, Sendable, Codable {

    public enum Outcome: Equatable, Sendable, Codable {
        case success
        /// Some items could not be processed (still worth reporting the rest).
        case partial(failedCount: Int)
        /// Nothing happened; `message` says why in plain words.
        case failed(message: String)
    }

    public let kind: CareFinding.Kind
    public let itemsProcessed: Int
    /// Bytes returned to the disk: gone for good, with nothing to restore.
    public let bytesFreed: Int64
    /// Bytes now in the Trash, which still occupy the disk and can be restored.
    public let bytesMovedToTrash: Int64
    public let outcome: Outcome

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(
        kind: CareFinding.Kind,
        itemsProcessed: Int,
        bytesFreed: Int64,
        bytesMovedToTrash: Int64 = 0,
        outcome: Outcome
    ) {
        self.kind = kind
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.bytesMovedToTrash = bytesMovedToTrash
        self.outcome = outcome
    }

    /// Written out so a receipt persisted before `bytesMovedToTrash` existed
    /// still decodes; `CareHistoryStore` drops the whole log on a decode failure.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(CareFinding.Kind.self, forKey: .kind)
        itemsProcessed = try container.decode(Int.self, forKey: .itemsProcessed)
        bytesFreed = try container.decode(Int64.self, forKey: .bytesFreed)
        bytesMovedToTrash = try container.decodeIfPresent(Int64.self, forKey: .bytesMovedToTrash) ?? 0
        outcome = try container.decode(Outcome.self, forKey: .outcome)
    }
}

/// Everything one Run pass accomplished, in the order the findings executed.
public struct CareReceipt: Equatable, Sendable, Codable {
    let date: Date
    public let lines: [CareReceiptLine]

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(date: Date, lines: [CareReceiptLine]) {
        self.date = date
        self.lines = lines
    }

    public var totalBytesFreed: Int64 {
        lines.reduce(0) { $0 + $1.bytesFreed }
    }

    public var totalBytesMovedToTrash: Int64 {
        lines.reduce(0) { $0 + $1.bytesMovedToTrash }
    }

    /// Whether this run moved anything to the Trash, so the receipt can offer a
    /// restore path. Junk qualifies only for the part of it that went there, and
    /// count-only actions never do — the note must not imply those are
    /// recoverable. The kind check covers recycled items with no measured size.
    public var hasTrashRecoverableItems: Bool {
        lines.contains { $0.bytesMovedToTrash > 0 || ($0.kind.movesToTrash && $0.itemsProcessed > 0) }
    }
}
