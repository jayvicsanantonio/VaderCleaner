// MenuBarViewModel.swift
// View-model backing the menu bar extra — exposes formatted RAM/disk strings the popover and label render.

import Foundation
import Combine

/// Drives the `MenuBarExtra` label and popover.
///
/// For Prompt 5 the values are static placeholders. Prompt 10 replaces the
/// `init` defaults with a `SystemStatsService` subscription that updates these
/// `@Published` strings every two seconds, so the popover and label re-render
/// without further view changes.
@MainActor
final class MenuBarViewModel: ObservableObject {

    /// Default placeholder shown until `SystemStatsService` (Prompt 10) starts
    /// publishing live values. Format mirrors what the live wiring will emit so
    /// the menu bar label width does not jump on first update.
    static let placeholderRAM = "RAM: 0.0 GB"
    static let placeholderDisk = "Disk: 0 GB free"

    @Published var formattedRAMUsage: String
    @Published var formattedDiskSpace: String

    init(
        ramUsage: String = MenuBarViewModel.placeholderRAM,
        diskSpace: String = MenuBarViewModel.placeholderDisk
    ) {
        self.formattedRAMUsage = ramUsage
        self.formattedDiskSpace = diskSpace
    }
}
