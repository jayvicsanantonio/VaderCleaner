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
        var threats: [MalwareThreat] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(foundSuffix) else { continue }

            let body = String(line.dropLast(foundSuffix.count))
            guard let separatorRange = body.range(of: separator, options: .backwards) else {
                continue
            }

            let path = String(body[..<separatorRange.lowerBound])
            let threatName = String(body[separatorRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !threatName.isEmpty else { continue }

            threats.append(MalwareThreat(
                filePath: URL(fileURLWithPath: path),
                threatName: threatName
            ))
        }
        return threats
    }
}
