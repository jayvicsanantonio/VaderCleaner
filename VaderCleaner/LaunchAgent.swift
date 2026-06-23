// LaunchAgent.swift
// Launch-agent / launch-daemon model and manager — discovers plists, reports launchctl-loaded status, and disables or removes them (user in-process, system via the privileged helper).

import Foundation
import os.log

/// A launchd job discovered under a LaunchAgents/LaunchDaemons directory.
struct LaunchAgent: Identifiable, Equatable {

    /// Where the plist lives — drives the disable/remove privilege split.
    enum Domain: Equatable {
        case user
        case system
    }

    /// The plist path is the stable identity: two jobs can legitimately
    /// share a `Label`, but never a path.
    var id: String { path.path }

    let label: String
    let path: URL
    let programPath: String?
    let isEnabled: Bool
    let domain: Domain

    /// True for a stub plist that defines no runnable job — no `Program` or
    /// `ProgramArguments` to exec — and isn't currently loaded. These are
    /// leftover files (e.g. retired Keystone tombstones) that can never be
    /// toggled on, so the UI offers only removal rather than a dead switch.
    var isOrphaned: Bool { programPath == nil && !isEnabled }

    /// A copy with `isEnabled` set to `value`. Used for the optimistic,
    /// in-place row update when toggling an agent, so the switch responds
    /// immediately without reloading the whole list.
    func settingEnabled(_ value: Bool) -> LaunchAgent {
        LaunchAgent(
            label: label, path: path, programPath: programPath,
            isEnabled: value, domain: domain
        )
    }
}

/// Discovers and manages launchd jobs for the Performance feature.
///
/// Collaborators (filesystem roots, `launchctl`, the loaded-label query, and
/// the privileged helper) are injected so the manager is unit-testable
/// without touching real launchd state.
struct LaunchAgentManager {

    typealias LoadedLabelsProvider = () -> Set<String>
    typealias LaunchctlRunner = (_ arguments: [String]) throws -> Void
    typealias HelperProvider = (@escaping (Error) -> Void) -> VaderCleanerHelperProtocol?

    private let userAgentsDirectory: URL
    private let systemAgentDirectories: [URL]
    private let fileManager: FileManager
    private let loadedLabels: LoadedLabelsProvider
    private let launchctl: LaunchctlRunner
    private let helperProvider: HelperProvider

    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "LaunchAgentManager")

    init(
        userAgentsDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        systemAgentDirectories: [URL] = [
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ],
        fileManager: FileManager = .default,
        loadedLabels: @escaping LoadedLabelsProvider = LaunchAgentManager.defaultLoadedLabels,
        launchctl: @escaping LaunchctlRunner = LaunchAgentManager.defaultLaunchctl,
        helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider
    ) {
        self.userAgentsDirectory = userAgentsDirectory
        self.systemAgentDirectories = systemAgentDirectories
        self.fileManager = fileManager
        self.loadedLabels = loadedLabels
        self.launchctl = launchctl
        self.helperProvider = helperProvider
    }

    // MARK: - Discovery

    /// Every `*.plist` under the user's `~/Library/LaunchAgents`.
    func userAgents() -> [LaunchAgent] {
        agents(in: [userAgentsDirectory], domain: .user)
    }

    /// Every `*.plist` under the system `/Library/LaunchAgents` and
    /// `/Library/LaunchDaemons` roots.
    func systemAgents() -> [LaunchAgent] {
        agents(in: systemAgentDirectories, domain: .system)
    }

    private func agents(in roots: [URL], domain: LaunchAgent.Domain) -> [LaunchAgent] {
        // Snapshot the loaded set once per pass rather than shelling out to
        // launchctl for every plist.
        let loaded = loadedLabels()
        var seen = Set<String>()
        var result: [LaunchAgent] = []

        for dir in roots {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            let entries = (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries where entry.pathExtension.lowercased() == "plist" {
                // A directory named `*.plist` is not a launch agent; only
                // regular files carry a launchd job definition.
                let isRegularFile = (try? entry.resourceValues(
                    forKeys: [.isRegularFileKey]
                ))?.isRegularFile ?? false
                guard isRegularFile, seen.insert(entry.path).inserted else { continue }
                let plist = (try? Data(contentsOf: entry)).flatMap {
                    try? PropertyListSerialization.propertyList(
                        from: $0, options: [], format: nil
                    ) as? [String: Any]
                } ?? [:]

                let label = (plist["Label"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? entry.deletingPathExtension().lastPathComponent

                result.append(LaunchAgent(
                    label: label,
                    path: entry,
                    programPath: Self.programPath(from: plist),
                    // "Loaded" (launchctl) is the spec's chosen signal. It can
                    // differ from the plist `Disabled` key — an agent may be
                    // loaded transiently without being enabled on disk — but
                    // loaded status is what reflects the running system.
                    // Authoritative for user agents only: `launchctl list`
                    // runs in the user's bootstrap and cannot enumerate
                    // system daemons, so this is best-effort for `.system`
                    // and the UI must not present it as a definitive badge.
                    isEnabled: loaded.contains(label),
                    domain: domain
                ))
            }
        }
        return result
    }

    // MARK: - Enable / disable

    /// Loads the job into launchd via `launchctl load -w <path>`. The `-w`
    /// flag clears the agent's entry in launchd's per-user override database
    /// (`/var/db/com.apple.xpc.launchd`), so an agent that was previously
    /// disabled there reliably re-registers instead of silently no-opping.
    /// User agents live in the caller's own launchd domain, so this needs no
    /// privilege escalation.
    func enable(_ agent: LaunchAgent) throws {
        try launchctl(["load", "-w", agent.path.path])
    }

    /// Unloads the job from launchd via `launchctl unload -w <path>`. The `-w`
    /// flag records the agent as disabled in launchd's per-user override
    /// database (`/var/db/com.apple.xpc.launchd`) so it stays off across logins
    /// rather than reloading on the next session. User agents live in the
    /// caller's own launchd domain, so this needs no privilege escalation.
    func disable(_ agent: LaunchAgent) throws {
        try launchctl(["unload", "-w", agent.path.path])
    }

    // MARK: - Remove

    /// Deletes the plist. User-domain plists are user-writable and removed
    /// in-process; system-domain plists under `/Library` require root and are
    /// routed through the privileged helper's `removeLaunchAgent(path:)`.
    func remove(_ agent: LaunchAgent) async throws {
        switch agent.domain {
        case .user:
            try fileManager.removeItem(at: agent.path)
        case .system:
            try await removeViaHelper(path: agent.path.path)
        }
    }

    /// Bridges the reply-block helper call to async/throwing. Installs both
    /// the per-call XPC error handler and the reply block so a dropped
    /// connection can't freeze removal — whichever fires first wins via the
    /// once-only `Resumer`.
    private func removeViaHelper(path: String) async throws {
        let error: Error? = await withCheckedContinuation { continuation in
            let resumer = LaunchAgentResumer(continuation: continuation)
            let helper = helperProvider { connectionError in
                resumer.resume(with: connectionError)
            }
            guard let helper else {
                resumer.resume(with: HelperConnectionError.unavailable)
                return
            }
            helper.removeLaunchAgent(path: path) { replyError in
                resumer.resume(with: replyError)
            }
        }
        if let error {
            log.error("Helper launch-agent removal failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Parsing

    /// Parses `launchctl list` output into the set of loaded job labels. The
    /// command emits a `PID\tStatus\tLabel` header followed by tab-separated
    /// rows; the label is always the final column.
    static func parseLoadedLabels(from output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let last = columns.last else { continue }
            let label = last.trimmingCharacters(in: .whitespaces)
            if label.isEmpty || label == "Label" { continue }
            labels.insert(label)
        }
        return labels
    }

    /// The job's executable: the `Program` key, else the first element of
    /// `ProgramArguments`.
    static func programPath(from plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty {
            return program
        }
        if let arguments = plist["ProgramArguments"] as? [String],
           let first = arguments.first, !first.isEmpty {
            return first
        }
        return nil
    }

    // MARK: - Production collaborators

    /// Runs `/bin/launchctl list` and parses the loaded labels. Returns an
    /// empty set on any failure — a missing label just renders as "disabled".
    static let defaultLoadedLabels: LoadedLabelsProvider = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr rather than wiring an unread Pipe — an unread pipe
        // whose buffer fills would deadlock `launchctl`.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return LaunchAgentManager.parseLoadedLabels(from: output)
        } catch {
            return []
        }
    }

    /// Runs `/bin/launchctl` with the given arguments, throwing on a non-zero
    /// exit so `disable` surfaces the failure.
    static let defaultLaunchctl: LaunchctlRunner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        // stdout is unused; discard it. stderr is read *before*
        // `waitUntilExit()` so a chatty failure can't deadlock the process
        // on a full pipe buffer, and is surfaced in the thrown error.
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = stderr.isEmpty
                ? "launchctl \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)"
                : stderr
            throw NSError(
                domain: "com.personal.VaderCleaner.LaunchAgentManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
}

/// Once-only continuation resume — the XPC reply block and the connection
/// error handler may both fire; `CheckedContinuation` traps on a second
/// resume, so the first wins and later attempts are dropped. Mirrors the same
/// guard used by `SystemJunkDeleter`.
private final class LaunchAgentResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?

    init(continuation: CheckedContinuation<Error?, Never>) {
        self.continuation = continuation
    }

    func resume(with error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: error)
    }
}
