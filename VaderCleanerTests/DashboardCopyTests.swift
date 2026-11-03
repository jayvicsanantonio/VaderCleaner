// DashboardCopyTests.swift
// Pins the finding-led headlines and size-led card copy the Protection and My Clutter dashboards share with the rest, including their singular forms, and the malware card's definitions status.

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
struct ProtectionDefinitionsStatusTests {

    @Test
    func whileAScanRuns_saysNothing() {
        // A scan refreshes stale signatures itself, so the card has nothing to offer.
        #expect(ProtectionMalwareTile.definitionsStatus(ageInDays: 0, isUpdating: false, failure: nil, isScanning: true) == nil)
    }

    @Test
    func reportsHowOldTheDefinitionsAre() {
        #expect(ProtectionMalwareTile.definitionsStatus(ageInDays: 0, isUpdating: false, failure: nil, isScanning: false)?.text
                == "Malware definitions updated today")
        #expect(ProtectionMalwareTile.definitionsStatus(ageInDays: 1, isUpdating: false, failure: nil, isScanning: false)?.text
                == "Malware definitions updated yesterday")
        #expect(ProtectionMalwareTile.definitionsStatus(ageInDays: 5, isUpdating: false, failure: nil, isScanning: false)?.text
                == "Malware definitions updated 5 days ago")
        #expect(ProtectionMalwareTile.definitionsStatus(ageInDays: nil, isUpdating: false, failure: nil, isScanning: false)?.text
                == "Malware definitions have never been updated")
    }

    @Test
    func whileUpdating_showsProgress() throws {
        let status = try #require(
            ProtectionMalwareTile.definitionsStatus(ageInDays: 3, isUpdating: true, failure: nil, isScanning: false)
        )

        #expect(status.isBusy)
        #expect(status.text == "Updating malware definitions…")
    }

    @Test
    func whileScanning_namesTheCurrentFileOnOneLine() throws {
        // On the status line rather than under the illustration, so it stays
        // when a short card drops the illustration.
        let status = try #require(
            ProtectionMalwareTile.currentFileStatus(progressLine: "/Users/me/Downloads/Installer.dmg: OK")
        )

        #expect(status.text == "Installer.dmg")
        #expect(status.isOneLine)
        #expect(status.identifier == "protection.malwareTile.currentFile")
        #expect(ProtectionMalwareTile.currentFileStatus(progressLine: "") == nil)
    }

    @Test
    func afterAFailedUpdate_showsWhyInPlaceOfTheAge() throws {
        let status = try #require(
            ProtectionMalwareTile.definitionsStatus(ageInDays: 3, isUpdating: false, failure: "No connection.", isScanning: false)
        )

        #expect(status.text == "No connection.")
        #expect(!status.isBusy)
        #expect(status.identifier == "protection.updateDefinitions.failure")
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
