// SeededSectionScans.swift
// Sequential starter for the standalone sections' follow-up scans after a Smart Scan — one section scans at a time so the machine stays responsive while the user reviews results.

import Foundation

/// Starts each still-idle coordinator's scan in order, waiting for one scan
/// to land before the next begins. ContentView hands this the sections it
/// populates after a Smart Scan: launching all of their scans at once pegged
/// every core (~400% CPU) and flooded the main actor with progress updates
/// right as the user starts reviewing results — the window where section
/// switches janked hardest. Sequencing keeps every section eventually
/// populated while the app stays responsive.
@MainActor
enum SeededSectionScans {

    /// Runs the chain. A coordinator that has already left its intro — the
    /// user scanned it by hand, or an earlier seed populated it — is skipped.
    /// An idle one is started, then awaited (by polling its coarse
    /// presentation) until its scan lands. A section the user resets back to
    /// its intro mid-scan also ends its wait, so the chain can never wedge on
    /// a Start Over.
    static func run(
        _ coordinators: [any ScanCoordinating],
        pollInterval: Duration = .seconds(1)
    ) async {
        for coordinator in coordinators {
            guard coordinator.scanPresentation == .intro else { continue }
            coordinator.beginScan()
            // `beginScan` spawns the scan as its own task, so the phase flip
            // out of the intro lands a beat later; wait that out first.
            while coordinator.scanPresentation == .intro {
                try? await Task.sleep(for: pollInterval)
            }
            while coordinator.scanPresentation == .working {
                try? await Task.sleep(for: pollInterval)
            }
        }
    }
}
