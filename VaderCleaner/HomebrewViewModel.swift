// HomebrewViewModel.swift
// State machine and orchestration behind the Homebrew Manager — inventories installed packages, checks for updates, and drives upgrade, dependency-aware uninstall, and cleanup as streamed, cancellable brew operations.

import Foundation
import Observation
import os.log

/// Drives the Homebrew Manager surface. All brew interaction flows through the
/// injected `BrewLocating` + `BrewRunning` seams so every phase is unit-testable
/// with stub responses and fixture output. Production wiring lives in
/// `HomebrewViewModel.live()`.
@MainActor
@Observable
final class HomebrewViewModel {

    /// Discrete phases the view binds to.
    enum Phase: Equatable {
        case idle
        case loading
        case notInstalled
        case ready
        case checkingUpdates
        case running(Operation)
        case failed(message: String)
    }

    /// A long-running mutating brew operation. Drives the progress overlay and
    /// the single-active-operation guard.
    enum Operation: Equatable {
        case upgrade
        case uninstall
        case cleanup
        case autoremove
    }

    /// The reclaimable-space preview from `brew cleanup -n`. `.unavailable`
    /// distinguishes "we ran the dry run but couldn't read a total" from a real
    /// zero, so the view never shows a fabricated number.
    enum ReclaimPreview: Equatable, Sendable {
        case bytes(Int64)
        case unavailable
    }

    /// Surfaced when an operation needs interactive elevation the app can't
    /// provide (a cask uninstaller invoking `sudo`) or stalls with no output —
    /// carries the exact command for the user to run in Terminal.
    struct ManualHandlingNotice: Equatable, Sendable {
        let command: String
    }

    private(set) var phase: Phase = .idle
    private(set) var inventory: [BrewPackage] = []
    private(set) var outdated: [BrewOutdatedItem] = []
    private(set) var reclaimablePreview: ReclaimPreview?
    private(set) var liveLog: [String] = []
    private(set) var pendingUninstall: UninstallConfirmation?
    private(set) var lastOperationError: String?
    private(set) var manualHandling: ManualHandlingNotice?
    private(set) var autoremovedNames: [String]?
    /// Set after a successful uninstall so the view can offer the autoremove +
    /// cleanup sweep as a continuation of the same flow.
    private(set) var postUninstallSweepAvailable = false

    typealias MakeRunner = @Sendable (URL) -> BrewRunning

    @ObservationIgnored private let locator: BrewLocating
    @ObservationIgnored private let makeRunner: MakeRunner
    @ObservationIgnored private let stallTimeout: TimeInterval
    @ObservationIgnored private var runner: BrewRunning?
    @ObservationIgnored private var activeStreamTask: Task<Int32, Error>?
    /// Guards `checkUpdatesIfNeeded` so entering the Updater's Homebrew facet
    /// runs the (network) update check at most once per session.
    @ObservationIgnored private var hasCheckedUpdates = false
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "HomebrewViewModel")

    /// - Parameter stallTimeout: seconds of no streamed output before an
    ///   operation is treated as stalled and routed to manual handling. Injected
    ///   so tests can drive the stall path quickly.
    init(
        locator: BrewLocating,
        makeRunner: @escaping MakeRunner,
        stallTimeout: TimeInterval = 120
    ) {
        self.locator = locator
        self.makeRunner = makeRunner
        self.stallTimeout = stallTimeout
    }

    /// `true` while any load, check, or mutating operation is in flight — the
    /// guard that prevents two brew operations from running at once.
    var isBusy: Bool {
        switch phase {
        case .loading, .checkingUpdates, .running:
            return true
        case .idle, .notInstalled, .ready, .failed:
            return false
        }
    }

    /// Count of packages with an update available, for the section glance.
    /// Pinned packages are still counted — they do have updates — but are
    /// excluded from "upgrade all".
    var availableUpdateCount: Int { outdated.count }

    // MARK: - Load

    /// Locates brew and loads the installed-package inventory. Absence drives
    /// `.notInstalled`; a present-but-failing brew drives `.failed`.
    func load() async {
        phase = .loading
        guard let brewURL = locator.locate() else {
            inventory = []
            phase = .notInstalled
            return
        }
        let runner = makeRunner(brewURL)
        self.runner = runner
        do {
            inventory = try await Self.loadInventory(runner: runner)
            phase = .ready
        } catch {
            log.error("Homebrew inventory load failed: \(String(describing: error), privacy: .private)")
            inventory = []
            phase = .failed(message: Self.message(for: error))
        }
    }

    /// Loads the inventory only if it hasn't started yet — used when a Homebrew
    /// facet is first shown, so brew isn't run on every manager open.
    func loadIfNeeded() async {
        if case .idle = phase { await load() }
    }

    private static func loadInventory(runner: BrewRunning) async throws -> [BrewPackage] {
        let leavesResult = try await runner.runCapturing(["leaves", "--installed-on-request"])
        let leaves = BrewOutputParser.parseLeaves(leavesResult.standardOutput)

        let formulaeResult = try await runner.runCapturing(["list", "--formula", "--versions"])
        let formulae = BrewOutputParser.parseListVersions(formulaeResult.standardOutput, kind: .formula, leaves: leaves)

        let casksResult = try await runner.runCapturing(["list", "--cask", "--versions"])
        let casks = BrewOutputParser.parseListVersions(casksResult.standardOutput, kind: .cask)

        return (formulae + casks).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Update check

    /// Refreshes formula/cask definitions (`brew update`, best-effort) then
    /// enumerates outdated packages. A failed `brew update` (e.g. offline) does
    /// not block the outdated read from local metadata.
    func checkUpdates() async {
        guard let runner, !isBusy else { return }
        phase = .checkingUpdates
        // Best-effort: an offline `brew update` must not blank the dashboard.
        _ = try? await runner.runCapturing(["update"])
        do {
            try await reloadOutdated(runner: runner)
            phase = .ready
        } catch {
            log.error("Homebrew outdated check failed: \(String(describing: error), privacy: .private)")
            phase = .failed(message: Self.message(for: error))
        }
    }

    /// Runs the outdated check at most once per session (it does a networked
    /// `brew update`), so re-entering the Updater's Homebrew facet doesn't
    /// re-hit the network. Requires the inventory to have loaded first so a
    /// runner exists.
    func checkUpdatesIfNeeded() async {
        guard !hasCheckedUpdates, runner != nil, !isBusy else { return }
        await checkUpdates()
        if case .ready = phase { hasCheckedUpdates = true }
    }

    private func reloadOutdated(runner: BrewRunning) async throws {
        let result = try await runner.runCapturing(["outdated", "--json=v2"])
        let items = try BrewOutputParser.parseOutdatedJSON(Data(result.standardOutput.utf8))
        outdated = items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Upgrade

    /// Upgrades all outdated packages (excluding pinned) or exactly the named
    /// selection, then refreshes the outdated dashboard.
    func upgrade(_ selection: UpgradeSelection) async {
        guard runner != nil, !isBusy else { return }
        let names: [String]
        switch selection {
        case .all:
            names = outdated.filter { !$0.isPinned }.map(\.name)
        case .some(let selected):
            names = selected
        }
        guard !names.isEmpty else { return }

        let status = await stream(.upgrade, arguments: ["upgrade"] + names)
        recordFailureIfNeeded(status, verb: "upgrade")
        if let runner { try? await reloadOutdated(runner: runner) }
        phase = .ready
    }

    // MARK: - Uninstall

    /// Runs the reverse-dependency check for each target and stages a
    /// confirmation. Casks have no formula dependency graph, so they never
    /// contribute blocking dependents.
    func requestUninstall(_ packages: [BrewPackage]) async {
        guard let runner, !isBusy, !packages.isEmpty else { return }
        var dependents: [String: [String]] = [:]
        for package in packages {
            guard package.kind == .formula else {
                dependents[package.name] = []
                continue
            }
            if let result = try? await runner.runCapturing(["uses", "--installed", package.name]) {
                dependents[package.name] = BrewOutputParser.parseUses(result.standardOutput)
            } else {
                dependents[package.name] = []
            }
        }
        pendingUninstall = UninstallConfirmation(targets: packages, dependents: dependents)
    }

    /// Discards the staged uninstall without removing anything.
    func cancelUninstallRequest() {
        pendingUninstall = nil
    }

    /// Removes the confirmed packages, then refreshes the inventory and offers
    /// the cleanup sweep.
    func confirmUninstall() async {
        guard let confirmation = pendingUninstall, !isBusy else { return }
        pendingUninstall = nil

        let formulae = confirmation.targets.filter { $0.kind == .formula }.map(\.name)
        let casks = confirmation.targets.filter { $0.kind == .cask }.map(\.name)

        var lastStatus: Int32?
        if !formulae.isEmpty {
            lastStatus = await stream(.uninstall, arguments: ["uninstall"] + formulae)
        }
        if !casks.isEmpty, manualHandling == nil {
            lastStatus = await stream(.uninstall, arguments: ["uninstall", "--cask"] + casks)
        }
        recordFailureIfNeeded(lastStatus, verb: "uninstall")

        if let runner { inventory = (try? await Self.loadInventory(runner: runner)) ?? inventory }
        postUninstallSweepAvailable = true
        phase = .ready
    }

    // MARK: - Cleanup / autoremove

    /// Runs `brew cleanup -n` and records the reclaimable total (or
    /// `.unavailable` when it can't be parsed).
    func previewCleanup() async {
        guard let runner, !isBusy else { return }
        guard let result = try? await runner.runCapturing(["cleanup", "-n"]) else {
            reclaimablePreview = .unavailable
            return
        }
        if let bytes = BrewOutputParser.parseCleanupDryRun(result.standardOutput) {
            reclaimablePreview = .bytes(bytes)
        } else {
            reclaimablePreview = .unavailable
        }
    }

    /// Removes stale versions and cached downloads.
    func runCleanup() async {
        guard runner != nil, !isBusy else { return }
        let status = await stream(.cleanup, arguments: ["cleanup"])
        recordFailureIfNeeded(status, verb: "cleanup")
        reclaimablePreview = nil
        phase = .ready
    }

    /// Removes dependencies no longer required by any installed package and
    /// records which were removed.
    func runAutoremove() async {
        guard runner != nil, !isBusy else { return }
        let status = await stream(.autoremove, arguments: ["autoremove"])
        recordFailureIfNeeded(status, verb: "autoremove")
        autoremovedNames = BrewOutputParser.parseAutoremove(liveLog.joined(separator: "\n"))
        if let runner { inventory = (try? await Self.loadInventory(runner: runner)) ?? inventory }
        phase = .ready
    }

    // MARK: - Cancellation

    /// Cancels the in-flight streamed operation; the child brew process is
    /// SIGTERM-ed and the surface returns to a stable state.
    func cancelActiveOperation() {
        activeStreamTask?.cancel()
    }

    /// Clears the "run in Terminal" notice once the user has acknowledged it.
    func dismissManualHandling() {
        manualHandling = nil
    }

    // MARK: - Streamed operation core

    /// Runs a mutating brew operation, streaming its output into `liveLog`,
    /// watching for a stall or interactive-elevation prompt, and honoring
    /// cancellation. Returns the termination status, or `nil` when cancelled.
    private func stream(_ operation: Operation, arguments: [String]) async -> Int32? {
        guard let runner else { return nil }
        liveLog = []
        lastOperationError = nil
        manualHandling = nil
        autoremovedNames = nil
        phase = .running(operation)

        let buffer = LineBuffer()
        let streamTask = Task<Int32, Error> {
            try await runner.runStreaming(arguments) { line in
                buffer.append(line)
            }
        }
        activeStreamTask = streamTask
        let monitor = makeMonitorTask(buffer: buffer, arguments: arguments)

        let status: Int32?
        do {
            status = try await streamTask.value
        } catch {
            status = nil
        }
        monitor.cancel()
        activeStreamTask = nil
        liveLog = buffer.snapshot()

        // Detect an interactive-elevation prompt in the captured output even
        // when the watchdog didn't fire (the process exited fast on closed
        // stdin) so the user is still routed to Terminal.
        if manualHandling == nil, Self.indicatesInteractiveElevation(liveLog) {
            manualHandling = ManualHandlingNotice(command: (["brew"] + arguments).joined(separator: " "))
        }
        return status
    }

    /// Pumps streamed output into the observable `liveLog` and watches for a
    /// stall: no output for `stallTimeout` seconds means the operation is
    /// treated as requiring manual handling and is cancelled.
    private func makeMonitorTask(buffer: LineBuffer, arguments: [String]) -> Task<Void, Never> {
        let stallTimeout = self.stallTimeout
        let pumpSeconds = min(stallTimeout, 0.5)
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pumpSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.liveLog = buffer.snapshot()
                if buffer.idleInterval() >= stallTimeout {
                    self.manualHandling = ManualHandlingNotice(
                        command: (["brew"] + arguments).joined(separator: " ")
                    )
                    self.activeStreamTask?.cancel()
                    return
                }
            }
        }
    }

    private func recordFailureIfNeeded(_ status: Int32?, verb: String) {
        guard manualHandling == nil, let status, status != 0 else { return }
        let tail = liveLog.suffix(3).joined(separator: " ")
        lastOperationError = "brew \(verb) exited with status \(status). \(tail)"
    }

    /// Matches the messages `sudo` prints when it can't prompt on a closed
    /// stdin, so a cask uninstaller that needs elevation is routed to Terminal.
    private static func indicatesInteractiveElevation(_ lines: [String]) -> Bool {
        lines.contains { line in
            let lower = line.lowercased()
            return lower.contains("a terminal is required")
                || lower.contains("password is required")
                || lower.contains("sudo:")
        }
    }

    private static func message(for error: Error) -> String {
        "Homebrew command failed: \(error.localizedDescription)"
    }
}

// MARK: - Thread-safe line buffer

/// Accumulates streamed lines off the main thread and tracks idle time for the
/// stall watchdog. `onLine` fires from the streamer's background read loop, so
/// the buffer is locked the same way other streamed callers guard accumulators.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var lastAppend = Date()

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lastAppend = Date()
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func idleInterval() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastAppend)
    }
}

// MARK: - Production wiring

extension HomebrewViewModel {

    /// Build a view model wired to the real brew locator and runner.
    @MainActor
    static func live() -> HomebrewViewModel {
        HomebrewViewModel(
            locator: DefaultBrewLocator(),
            makeRunner: { url in DefaultBrewRunner(brewURL: url) }
        )
    }
}
