// DashboardCopyTests.swift
// Pins the finding-led headlines and size-led card copy the Protection and My Clutter dashboards share with the rest, including their singular forms.

import Foundation
import Testing
import VaderCleanerCore
@testable import VaderCleaner

@MainActor
@Suite
struct ProtectionDashboardCopyTests {

    private let threat = MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")

    @Test
    func headline_saysWhatTheMalwareScanFound() {
        #expect(ProtectionDashboardView.headline(for: .results([threat])) == "1 threat found on your Mac.")
        #expect(ProtectionDashboardView.headline(for: .results([threat, threat])) == "2 threats found on your Mac.")
        #expect(ProtectionDashboardView.headline(for: .done(removedCount: 1)) == "1 threat removed from your Mac.")
        #expect(ProtectionDashboardView.headline(for: .done(removedCount: 3)) == "3 threats removed from your Mac.")
    }

    @Test
    func headline_claimsACleanResultOnlyForThisScan() {
        // The clean result covers the areas the scan checked, not the whole Mac.
        #expect(ProtectionDashboardView.headline(for: .clean) == "No threats found in this scan.")
    }

    @Test
    func headline_reportsAScanThatIsRunningOrDidNotFinish() {
        #expect(ProtectionDashboardView.headline(for: .scanning(progress: "")) == "Looking for threats…")
        #expect(ProtectionDashboardView.headline(for: .failed(message: "Boom")) == "The malware scan didn't finish.")
        #expect(ProtectionDashboardView.headline(for: .idle) == "The malware scan was stopped.")
    }

    @Test
    func browserTileTitle_leadsWithTheSizeWhenItIsKnown() {
        let size = formattedFileBytes(4_780_000_000)
        #expect(ProtectionDashboardView.browserTileTitle(browserName: "Google Chrome", bytes: 4_780_000_000)
                == "\(size) of Google Chrome Browsing Data Found")
        #expect(ProtectionDashboardView.browserTileTitle(browserName: "Safari", bytes: 0)
                == "Safari Browsing Data Found")
    }
}

@MainActor
@Suite
struct MyClutterDashboardCopyTests {

    @Test
    func titles_leadWithTheReclaimableSize() {
        let size = formattedFileBytes(164_600_000)
        #expect(MyClutterDashboardView.duplicatesTitle(bytes: 164_600_000) == "\(size) of Duplicates Found")
        #expect(MyClutterDashboardView.similarTitle(bytes: 164_600_000) == "\(size) of Similar Images Found")
    }

    @Test
    func details_useTheSingularForOne() {
        #expect(MyClutterDashboardView.duplicatesDetail(count: 1) == "1 duplicate copy you can remove.")
        #expect(MyClutterDashboardView.similarDetail(count: 1) == "1 nearly identical photo.")
        #expect(MyClutterDashboardView.largeOldDetail(count: 1) == "1 large or long-unopened file.")
        #expect(MyClutterDashboardView.downloadsDetail(count: 1) == "1 downloaded file to look through.")
    }

    @Test
    func details_usePluralForMany() {
        #expect(MyClutterDashboardView.duplicatesDetail(count: 14_074).hasSuffix("duplicate copies you can remove."))
        #expect(MyClutterDashboardView.similarDetail(count: 2) == "2 nearly identical photos.")
        #expect(MyClutterDashboardView.largeOldDetail(count: 2) == "2 large or long-unopened files.")
        #expect(MyClutterDashboardView.downloadsDetail(count: 2) == "2 downloaded files to look through.")
    }
}
