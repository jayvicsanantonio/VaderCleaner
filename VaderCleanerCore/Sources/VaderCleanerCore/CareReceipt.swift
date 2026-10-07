// CareReceipt.swift
// The readable record of one Run pass: per-finding outcome lines with items processed and bytes freed. Codable so scan history can persist receipts.

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
    public let bytesFreed: Int64
    public let outcome: Outcome

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(kind: CareFinding.Kind, itemsProcessed: Int, bytesFreed: Int64, outcome: Outcome) {
        self.kind = kind
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.outcome = outcome
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

    /// Whether this run moved anything to the Trash, so the receipt can offer a
    /// restore path. Junk (a permanent delete) and count-only actions never
    /// qualify — the note must not imply those are recoverable.
    public var hasTrashRecoverableItems: Bool {
        lines.contains { $0.kind.movesToTrash && $0.itemsProcessed > 0 }
    }
}
