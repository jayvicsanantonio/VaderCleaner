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
        // These are independent read-only queries that don't lock the Homebrew
        // DB, so run them concurrently to cut inventory load time.
        async let leavesResult = runner.runCapturing(["leaves", "--installed-on-request"])
        async let formulaeResult = runner.runCapturing(["list", "--formula", "--versions"])
        async let casksResult = runner.runCapturing(["list", "--cask", "--versions"])
        let (leavesR, formulaeR, casksR) = try await (leavesResult, formulaeResult, casksResult)

        let leaves = BrewOutputParser.parseLeaves(try successfulOutput(leavesR, command: "brew leaves"))
        let formulae = BrewOutputParser.parseListVersions(
            try successfulOutput(formulaeR, command: "brew list --formula"), kind: .formula, leaves: leaves)
        let casks = BrewOutputParser.parseListVersions(
            try successfulOutput(casksR, command: "brew list --cask"), kind: .cask)

        return (formulae + casks).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Returns a command's stdout, or throws when brew exited non-zero — so a
    /// failed query is never parsed as valid (empty) output. Most importantly
    /// this keeps a failed `brew uses` from being read as "no dependents".
    private static func successfulOutput(_ result: BrewResult, command: String) throws -> String {
        guard result.terminationStatus == 0 else {
            throw BrewCommandError(command: command, status: result.terminationStatus, standardError: result.standardError)
        }
        return result.standardOutput
    }

    // MARK: - Update check

    /// Refreshes formula/cask definitions (`brew update`, best-effort) then
    /// enumerates outdated packages. A failed `brew update` (e.g. offline) does
    /// not block the outdated read from local metadata.
    func checkUpdates() async {
        guard let runner, !isBusy else { return }
        phase = .checkingUpdates
        lastOperationError = nil
        // Best-effort: an offline `brew update` must not blank the dashboard,
        // but its failure is surfaced (Req 4.5) rather than silently swallowed.
        let updateResult = try? await runner.runCapturing(["update"])
        if updateResult == nil || updateResult?.terminationStatus != 0 {
            lastOperationError = String(
                localized: "Couldn't refresh Homebrew — showing locally known outdated packages.",
                comment: "Non-blocking warning when `brew update` fails during the update check."
            )
        }
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
        let json = try Self.successfulOutput(result, command: "brew outdated")
        let items = try BrewOutputParser.parseOutdatedJSON(Data(json.utf8))
        outdated = items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Upgrade

    /// Upgrades all outdated packages (excluding pinned) or exactly the named
    /// selection, then refreshes the outdated dashboard.
    func upgrade(_ selection: UpgradeSelection) async {
        guard runner != nil, !isBusy else { return }
        // Pinned formulae are held back from upgrades whether the caller asked
        // for all outdated or an explicit selection.
        let pinnedNames = Set(outdated.filter(\.isPinned).map(\.name))
        let names: [String]
        switch selection {
        case .all:
            names = outdated.filter { !$0.isPinned }.map(\.name)
        case .some(let selected):
            names = selected.filter { !pinnedNames.contains($0) }
        }
        guard !names.isEmpty else { return }

        lastOperationError = nil
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
        // Reverse-dependency checks are independent read-only queries; run them
        // concurrently so the confirmation sheet isn't gated on a serial loop.
        var dependents: [String: [String]] = [:]
        await withTaskGroup(of: (String, [String]).self) { group in
            for package in packages {
                group.addTask {
                    // Casks have no formula dependency graph.
                    guard package.kind == .formula else { return (package.name, []) }
                    // A failed `brew uses` must NOT read as "no dependents" — that
                    // would green-light an unsafe removal. Treat it as an unknown
                    // (blocking) dependent so the user is warned.
                    guard let result = try? await runner.runCapturing(["uses", "--installed", package.name]),
                          result.terminationStatus == 0 else {
                        return (package.name, [String(
                            localized: "unknown (dependency check failed)",
                            comment: "Placeholder dependent shown when `brew uses` couldn't be run."
                        )])
                    }
                    return (package.name, BrewOutputParser.parseUses(result.standardOutput))
                }
            }
            for await (name, deps) in group { dependents[name] = deps }
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
        lastOperationError = nil

        let formulae = confirmation.targets.filter { $0.kind == .formula }.map(\.name)
        let casks = confirmation.targets.filter { $0.kind == .cask }.map(\.name)

        // Record each step's result independently so a formula failure can't be
        // masked by a later cask success (and vice versa).
        var allSucceeded = true
        if !formulae.isEmpty {
            let status = await stream(.uninstall, arguments: ["uninstall"] + formulae)
            recordFailureIfNeeded(status, verb: "uninstall")
            if status != 0 { allSucceeded = false }
        }
        if !casks.isEmpty, manualHandling == nil {
            let status = await stream(.uninstall, arguments: ["uninstall", "--cask"] + casks)
            recordFailureIfNeeded(status, verb: "uninstall")
            if status != 0 { allSucceeded = false }
        }

        if let runner { inventory = (try? await Self.loadInventory(runner: runner)) ?? inventory }
        // Only offer the cleanup sweep when every requested removal succeeded and
        // nothing was routed to Terminal or cancelled.
        postUninstallSweepAvailable = allSucceeded && manualHandling == nil
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
        lastOperationError = nil
        let status = await stream(.cleanup, arguments: ["cleanup"])
        recordFailureIfNeeded(status, verb: "cleanup")
        reclaimablePreview = nil
        phase = .ready
    }

    /// Removes dependencies no longer required by any installed package and
    /// records which were removed.
    func runAutoremove() async {
        guard runner != nil, !isBusy else { return }
        lastOperationError = nil
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
        // Note: `lastOperationError` is intentionally NOT reset here — a caller
        // that chains two streams (formula then cask uninstall) must not have the
        // first step's failure wiped by the second. Callers reset it once up front.
        liveLog = []
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
        } catch is CancellationError {
            // Genuine cancellation — return to a stable state with no error.
            status = nil
        } catch {
            // A launch / I/O / runner failure, not a cancellation: surface it.
            status = nil
            lastOperationError = Self.message(for: error)
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
        if let brewError = error as? BrewCommandError {
            return brewError.userFacingMessage
        }
        return "Homebrew command failed: \(error.localizedDescription)"
    }
}

/// A brew command that exited non-zero. Carries the captured stderr so the
/// failure can be surfaced instead of being parsed as valid (empty) output.
struct BrewCommandError: Error {
    let command: String
    let status: Int32
    let standardError: String

    var userFacingMessage: String {
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(command) failed (status \(status))"
        return detail.isEmpty ? base : "\(base): \(detail)"
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
