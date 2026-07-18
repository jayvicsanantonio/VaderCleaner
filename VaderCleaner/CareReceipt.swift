// CareReceipt.swift
// The readable record of one Run pass: per-finding outcome lines with items processed and bytes freed. Codable so scan history can persist receipts.

import Foundation

/// One line of the receipt: what Run did about one finding. `kind` keys the
/// plain-language copy; the outcome distinguishes clean success from partial
/// work and honest failure so nothing is silently glossed over.
struct CareReceiptLine: Equatable, Sendable, Codable {

    enum Outcome: Equatable, Sendable, Codable {
        case success
        /// Some items could not be processed (still worth reporting the rest).
        case partial(failedCount: Int)
        /// Nothing happened; `message` says why in plain words.
        case failed(message: String)
    }

    let kind: CareFinding.Kind
    let itemsProcessed: Int
    let bytesFreed: Int64
    let outcome: Outcome
}

/// Everything one Run pass accomplished, in the order the findings executed.
struct CareReceipt: Equatable, Sendable, Codable {
    let date: Date
    let lines: [CareReceiptLine]

    var totalBytesFreed: Int64 {
        lines.reduce(0) { $0 + $1.bytesFreed }
    }

    /// Lines that failed outright — the receipt calls these out in amber.
    var failedLines: [CareReceiptLine] {
        lines.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
    }
}
