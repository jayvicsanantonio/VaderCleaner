// ClamAVOutputParser.swift
// Parses clamscan stdout into typed MalwareThreat values, isolating the infected lines from OK/ERROR/summary noise.

import Foundation

/// Turns raw `clamscan` output into `MalwareThreat` values.
///
/// `clamscan` prints one line per scanned file using the format
/// `"<path>: <signature> FOUND"` for hits, `"<path>: OK"` for clean files,
/// and `"<path>: <reason> ERROR"` for files it couldn't read. Only the
/// `FOUND` lines are threats; everything else (including the
/// `----- SCAN SUMMARY -----` block) is ignored.
enum ClamAVOutputParser {

    /// Suffix every infected line ends with. clamscan signature names never
    /// contain spaces, so this token unambiguously marks a hit.
    private static let foundSuffix = " FOUND"

    /// Separator clamscan writes between the file path and the signature
    /// name. A path may legitimately contain `": "`, so the split is taken
    /// at the *last* occurrence — the threat name is always the final field.
    private static let separator = ": "

    static func parse(_ output: String) -> [MalwareThreat] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
    }

    /// Parses a single `clamscan` line, returning a threat only for an
    /// infected (`… FOUND`) verdict. `OK`, `ERROR`, summary, and progress
    /// lines yield `nil`. Used by the scanner to parse output as it streams
    /// rather than buffering the whole run.
    static func parseLine(_ rawLine: String) -> MalwareThreat? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasSuffix(foundSuffix) else { return nil }

        let body = String(line.dropLast(foundSuffix.count))
        guard let separatorRange = body.range(of: separator, options: .backwards) else {
            return nil
        }

        let path = String(body[..<separatorRange.lowerBound])
        let threatName = String(body[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !threatName.isEmpty else { return nil }

        return MalwareThreat(
            filePath: URL(fileURLWithPath: path),
            threatName: threatName
        )
    }
}
