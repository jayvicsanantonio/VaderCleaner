// SmartScanViewModel.swift
// State machine behind the Smart Scan feature view — orchestrates the System Junk, Malware, and Optimization sub-modules into one concurrent scan, aggregates their results, and drives a single junk+threats clean pass.

import Foundation
import os.log

/// One aggregated Smart Scan result, holding each sub-module's findings so the
/// results screen can render a card per module. `clamAVAvailable` lets the
/// Malware card hide its remove action when ClamAV is absent (the scan was
/// skipped, so an empty `threats` list there is "unknown", not "clean").
struct SmartScanResult: Equatable {
    let junkResult: ScanResult
    let threats: [MalwareThreat]
    let optimizationItems: [LoginItem]
    let clamAVAvailable: Bool

    /// "Total bytes found" is the System Junk byte total: detected threats and
    /// login items don't correspond to freeable bytes, so they don't
    /// contribute. Named explicitly so the contract is unambiguous.
    var totalJunkBytes: Int64 { junkResult.totalSize }
}

/// What a Smart Scan clean pass accomplished. Login items are intentionally
/// absent — Optimization is a *Review* (navigate) action, not a cleaner, so it
/// frees no bytes and removes no threats.
struct SmartScanSummary: Equatable {
    let bytesFreed: Int64
    let threatsRemoved: Int
}

/// Drives the Smart Scan feature view (scan → results → clean → done).
/// Collaborators are injected as closures — each mirrors the contract of the
/// sub-module it fronts — so unit tests can exercise every transition without
/// touching the real filesystem, ClamAV, or the privileged helper. Production
/// wiring lives in `SmartScanViewModel.live(exclusions:)`.
@MainActor
final class SmartScanViewModel: ObservableObject {

    /// Discrete phases the view binds to. The happy path is
    /// `idle → scanning → results → cleaning → done`; `failed` carries a
    /// message to surface.
    enum Phase: Equatable {
        case idle
        case scanning(phase: String)
        case results(SmartScanResult)
        case cleaning
        case done(summary: SmartScanSummary)
        case failed(message: String)
    }

    /// System Junk scan source. Throwing: a failed junk scan fails the whole
    /// Smart Scan, mirroring `SystemJunkViewModel.Scanner`.
    typealias JunkScanner = () async throws -> ScanResult
    /// Whether ClamAV is installed. When `false` the malware scan is skipped
    /// entirely and the Malware card hides its action.
    typealias MalwareInstalled = () -> Bool
    /// Malware scan source. Non-throwing and best-effort: a broken ClamAV
    /// install must not fail an otherwise-useful Smart Scan, so the live
    /// wiring logs and yields `[]` rather than propagating.
    typealias MalwareScanner = () async -> [MalwareThreat]
    /// Login-item loader, mirroring `OptimizationViewModel.LoadLoginItems`.
    typealias LoginItemsLoader = () async -> [LoginItem]
    /// Junk deletion sink — returns the bytes actually freed, mirroring
    /// `SystemJunkViewModel.Deleter`.
    typealias JunkCleaner = ([ScannedFile]) async throws -> Int64
    /// Threat remover — returns the threats it could **not** remove (empty ==
    /// full success), mirroring `MalwareViewModel.RemoveThreats`.
    typealias ThreatRemover = ([MalwareThreat]) async -> [MalwareThreat]

    @Published private(set) var phase: Phase = .idle

    private let junkScanner: JunkScanner
    private let malwareInstalled: MalwareInstalled
    private let malwareScanner: MalwareScanner
    private let loginItemsLoader: LoginItemsLoader
    private let junkCleaner: JunkCleaner
    private let threatRemover: ThreatRemover

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "SmartScanViewModel")

    init(
        junkScanner: @escaping JunkScanner,
        malwareInstalled: @escaping MalwareInstalled,
        malwareScanner: @escaping MalwareScanner,
        loginItemsLoader: @escaping LoginItemsLoader,
        junkCleaner: @escaping JunkCleaner,
        threatRemover: @escaping ThreatRemover
    ) {
        self.junkScanner = junkScanner
        self.malwareInstalled = malwareInstalled
        self.malwareScanner = malwareScanner
        self.loginItemsLoader = loginItemsLoader
        self.junkCleaner = junkCleaner
        self.threatRemover = threatRemover
    }

    // MARK: - Scan

    /// Runs the three sub-scans concurrently and lands `.results` (or
    /// `.failed` if the junk scan throws). The ClamAV install check is read
    /// once up front so the result can record whether the malware scan was
    /// actually performed.
    func scan() async {
        phase = .scanning(phase: String(
            localized: "Scanning for junk, malware, and optimization opportunities…",
            comment: "Progress label shown while the Smart Scan runs all sub-scans."
        ))

        let clamAVAvailable = malwareInstalled()

        async let junk = junkScanner()
        async let threats = scanForThreatsIfPossible(clamAVAvailable: clamAVAvailable)
        async let login = loginItemsLoader()

        do {
            let junkResult = try await junk
            let foundThreats = await threats
            let loginItems = await login

            phase = .results(SmartScanResult(
                junkResult: junkResult,
                threats: foundThreats,
                optimizationItems: loginItems,
                clamAVAvailable: clamAVAvailable
            ))
        } catch {
            log.error("Smart Scan failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Runs the malware scan only when ClamAV is present. Factored out of
    /// `scan()` so the `async let` site stays readable and the gating logic
    /// isn't buried in a conditional async closure.
    private func scanForThreatsIfPossible(clamAVAvailable: Bool) async -> [MalwareThreat] {
        guard clamAVAvailable else { return [] }
        return await malwareScanner()
    }

    // MARK: - Clean

    /// Single clean pass over the latest results: cleans the scanned junk,
    /// then removes the detected threats, and lands `.done` with a summary.
    /// Login items are intentionally untouched — the Optimization card is a
    /// *Review* (navigate) action, not part of the clean.
    /// A no-op unless we are showing results.
    func clean() async {
        guard case .results(let result) = phase else { return }
        phase = .cleaning

        do {
            let bytesFreed = try await junkCleaner(result.junkResult.items)
            let failures = await threatRemover(result.threats)
            let threatsRemoved = result.threats.count - failures.count
            if !failures.isEmpty {
                log.error("\(failures.count, privacy: .public) of \(result.threats.count, privacy: .public) threats could not be removed during Smart Scan clean")
            }
            phase = .done(summary: SmartScanSummary(
                bytesFreed: bytesFreed,
                threatsRemoved: threatsRemoved
            ))
        } catch {
            log.error("Smart Scan clean failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Recovery

    /// Returns to idle from a terminal phase so the user can start over.
    func reset() {
        phase = .idle
    }
}

// MARK: - Production wiring

extension SmartScanViewModel {

    /// Builds a view-model wired to the real System Junk scanner/deleter, the
    /// ClamAV detector/scanner, the malware threat remover, and the login-item
    /// manager — the same collaborators the individual feature `.live()`
    /// factories use, so Smart Scan and the standalone sections never diverge.
    ///
    /// The exclusions snapshot is captured per scan so a freshly-added
    /// Preferences exclusion takes effect on the next run, matching
    /// `SystemJunkViewModel.live`.
    @MainActor
    static func live(exclusions: ExclusionsStore) -> SmartScanViewModel {
        let detector = ClamAVDetector()
        let scanner = ClamAVScanner(detector: detector)
        let remover = MalwareThreatRemover()
        let loginManager = LoginItemsManager.live()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let log = Logger(subsystem: "com.personal.VaderCleaner",
                         category: "SmartScanViewModel.live")

        return SmartScanViewModel(
            junkScanner: { [weak exclusions] in
                let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
                return try await SystemJunkScanner().scan(excluding: excluded)
            },
            malwareInstalled: { detector.isInstalled() },
            // Best-effort: a missing signature database or a broken clamscan
            // binary must not sink an otherwise-useful Smart Scan. We log the
            // failure (rather than swallow it silently) so an unexpectedly
            // empty Malware card is debuggable, then degrade to "no threats".
            malwareScanner: {
                do {
                    return try await scanner.scan(paths: [home], progress: { _ in })
                } catch {
                    log.error("Smart Scan malware sub-scan failed, treating as no threats: \(String(describing: error), privacy: .public)")
                    return []
                }
            },
            loginItemsLoader: { loginManager.items() },
            junkCleaner: { try await SystemJunkDeleter().delete($0) },
            threatRemover: { await remover.remove($0) }
        )
    }
}
