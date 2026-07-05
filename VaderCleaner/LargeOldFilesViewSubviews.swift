// LargeOldFilesViewSubviews.swift
// Shared state screens (scanning, empty, failed) and pure formatting/summary helpers for the file-walk scan, reused by the My Clutter section.

import SwiftUI
import AppKit

enum LargeOldFilesFormatting {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

/// Pure strings for the results header above the file list: a headline file
/// count and a supporting detail line. Kept free of any view so the phrasing
/// is unit-testable without rendering.
enum LargeOldFilesSummary {
    /// Headline metric — the bare, pluralized file count, e.g. "142 files".
    static func headline(count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s")"
    }

    /// Full-sentence headline for the dashboard, echoing the Applications
    /// section's "We've found N apps on your Mac." phrasing.
    static func foundSentence(count: Int) -> String {
        let format = String(
            localized: "We've found %lld large or old files on your Mac.",
            comment: "Large & Old Files dashboard headline; %lld is the file count."
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }

    /// Supporting detail — the count of age-qualified files and the total
    /// reclaimable size, separated by a middle dot. The old-file clause is
    /// dropped when nothing qualified so the line never reads "0 older than
    /// six months". Takes precomputed aggregates so the header never re-scans a
    /// huge result set on render.
    static func detail(oldCount: Int, totalBytes: Int64) -> String {
        let totalClause = LargeOldFilesFormatting.byteFormatter.string(fromByteCount: totalBytes) + " total"
        guard oldCount > 0 else { return totalClause }
        return "\(oldCount) older than 6 months · \(totalClause)"
    }

    // Convenience overloads that derive the aggregates from a file array — used
    // by tests and any caller that hasn't already summarized the set.

    static func headline(for files: [ScannedFile]) -> String {
        headline(count: files.count)
    }

    static func foundSentence(for files: [ScannedFile]) -> String {
        foundSentence(count: files.count)
    }

    static func detail(for files: [ScannedFile]) -> String {
        var totalBytes: Int64 = 0
        var oldCount = 0
        for file in files {
            totalBytes += file.size
            if file.category == .oldFile { oldCount += 1 }
        }
        return detail(oldCount: oldCount, totalBytes: totalBytes)
    }
}

struct LargeOldFilesProgressState: View {
    let label: String
    let identifier: String
    /// Optional live progress line (e.g. "12,431 items") shown beneath the
    /// status phrase so the user can see an open-ended scan advancing.
    var detail: String? = nil
    /// Rotating personality phrases for the open scan; falls back to `label`.
    var phrases: [String]? = nil

    var body: some View {
        VStack(spacing: 16) {
            ScanProgressIndicator()
            ScanningStatusView(
                phrases: phrases ?? [label],
                count: detail,
                countIdentifier: "\(identifier).count"
            )
        }
        .padding()
        .accessibilityIdentifier(identifier)
    }
}

struct LargeOldFilesEmptyState: View {
    let onScanAgain: () -> Void
    /// Current Full Disk Access state. Drives whether the inline reminder
    /// appears under the "Scan Again" CTA — without it the user can't tell
    /// whether the empty result is genuine or just FDA-blocked.
    let hasFullDiskAccess: Bool
    /// Re-runs the FDA check. Wired to `AppState.refresh()` so the card can
    /// fade out the moment the user grants access in System Settings.
    let onRefreshAccess: () -> Void

    /// Pure predicate so the gate is unit-testable without rendering. The
    /// per-section "this scan needs FDA" decision lives in
    /// `NavigationSection.requiresFullDiskAccess`; here it is unconditional
    /// because the file-walk scan always requires FDA to read ~/Library.
    var shouldShowFullDiskAccessReminder: Bool { !hasFullDiskAccess }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Nothing to clean up")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("large-old.emptyTitle")
            Text("No files larger than 50 MB or untouched for the past six months were found in your home folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan Again", action: onScanAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("large-old.scanAgain")

            if shouldShowFullDiskAccessReminder {
                FullDiskAccessPromptCard(
                    accent: .teal,
                    onRecheck: onRefreshAccess
                )
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding()
        .animation(.smooth(duration: 0.4), value: hasFullDiskAccess)
    }
}

/// Which step of a file-walk flow produced a failure, so the failed screen can
/// pick the right heading. A standalone enum (rather than nested on a view
/// model) so the shared failed-state view stays usable across sections.
enum LargeOldFilesFailureStage: Equatable {
    case scanning
    case deleting
}

struct LargeOldFilesFailedState: View {
    let stage: LargeOldFilesFailureStage
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .scanning ? "Couldn't complete the scan" : "Couldn't finish deleting")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("large-old.errorMessage")
            Button("Try Again", action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("large-old.tryAgain")
        }
        .padding()
    }
}

extension ScannedFile: Identifiable {
    var id: URL { url }
}
