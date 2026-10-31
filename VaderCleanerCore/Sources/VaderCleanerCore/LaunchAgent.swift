// LaunchAgent.swift
// Launch-agent / launch-daemon model and manager — discovers plists, reports launchctl-loaded status, and disables or removes them (a user agent is stopped and moved to the Trash, a system one goes through the privileged helper).

import Foundation
import os.log

/// A launchd job discovered under a LaunchAgents/LaunchDaemons directory.
public struct LaunchAgent: Identifiable, Equatable, Sendable {

    /// Where the plist lives — drives the disable/remove privilege split.
    public enum Domain: Equatable, Sendable {
        case user
        case system
    }

    /// The plist path is the stable identity: two jobs can legitimately
    /// share a `Label`, but never a path.
    public var id: String { path.path }

    public let label: String
    public let path: URL
    public let programPath: String?
    public let isEnabled: Bool
    let domain: Domain

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(label: String, path: URL, programPath: String?, isEnabled: Bool, domain: Domain) {
        self.label = label
        self.path = path
        self.programPath = programPath
        self.isEnabled = isEnabled
        self.domain = domain
    }

    /// True for a stub plist that defines no runnable job — no `Program` or
    /// `ProgramArguments` to exec — and isn't currently loaded. These are
    /// leftover files (e.g. retired Keystone tombstones) that can never be
    /// toggled on, so the UI offers only removal rather than a dead switch.
    public var isOrphaned: Bool { programPath == nil && !isEnabled }

    /// The app bundle the job's program lives inside, so an updater can show
    /// its parent app's icon. Matched per path component because a bare
    /// `.app` substring also appears in `com.apple.helper` and `tool.appdata`.
    public var appBundlePath: String? {
        guard let programPath else { return nil }
        let components = programPath.components(separatedBy: "/")
        guard let index = components.firstIndex(where: {
            $0.lowercased().hasSuffix(".app")
        }) else { return nil }
        return components[...index].joined(separator: "/")
    }

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

/// Failures `LaunchAgentManager` raises itself, with user-facing messages.
enum LaunchAgentError: LocalizedError {
    case couldNotMoveToTrash(label: String)
    case stateDidNotChange(label: String)

    var errorDescription: String? {
        switch self {
        case .couldNotMoveToTrash(let label):
            let format = String(
                localized: "Couldn't move “%@” to the Trash. Check that you have permission to change it, then try again.",
                bundle: .module,
                comment: "Error when a background item's file can't be trashed; %@ is its label."
            )
            return String.localizedStringWithFormat(format, label)
        case .stateDidNotChange(let label):
            let format = String(
                localized: "macOS didn't apply the change to “%@”.",
                bundle: .module,
                comment: "Error when launchd still reports a background item in its old state; %@ is its label."
            )
            return String.localizedStringWithFormat(format, label)
        }
    }
}

/// Discovers and manages launchd jobs for the Performance feature.
///
/// Collaborators (filesystem roots, `launchctl`, the loaded-label query, and
/// the privileged helper) are injected so the manager is unit-testable
/// without touching real launchd state.
struct LaunchAgentManager: Sendable {

    typealias LoadedLabelsProvider = @Sendable () -> Set<String>
    typealias LaunchctlRunner = @Sendable (_ arguments: [String]) throws -> Void
    typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?
    /// Moves files to the Trash and returns the ones that moved.
    typealias Recycle = @Sendable ([URL]) async -> Set<URL>

    /// The domain of the error `defaultLaunchctl` throws on a non-zero exit,
    /// whose code is the exit status.
    static let launchctlErrorDomain = "com.personal.VaderCleaner.LaunchAgentManager"
    /// `launchctl bootout`'s exit statuses for a job launchd doesn't have
    /// loaded: "No such process" and "Could not find service".
    private static let notLoadedExitStatuses: Set<Int> = [3, 113]

    private let userAgentsDirectory: URL
    private let systemAgentDirectories: [URL]
    /// See `DefaultAppDiscovery.fileManager` — `.default` is documented
    /// thread-safe and test fixtures are single-threaded.
    nonisolated(unsafe) private let fileManager: FileManager
    private let loadedLabels: LoadedLabelsProvider
    private let launchctl: LaunchctlRunner
    private let helperProvider: HelperProvider
    private let recycle: Recycle

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
        helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider,
        recycle: @escaping Recycle = { await UserFileRecycler.recycle($0, context: "LaunchAgentManager") }
    ) {
        self.userAgentsDirectory = userAgentsDirectory
        self.systemAgentDirectories = systemAgentDirectories
        self.fileManager = fileManager
        self.loadedLabels = loadedLabels
        self.launchctl = launchctl
        self.helperProvider = helperProvider
        self.recycle = recycle
    }

    // MARK: - Discovery

    /// Every `*.plist` under the user's `~/Library/LaunchAgents`.
    func userAgents() -> [LaunchAgent] {
        agents(in: [userAgentsDirectory], domain: .user, loaded: loadedLabels())
    }

    /// Every `*.plist` under the system `/Library/LaunchAgents` and
    /// `/Library/LaunchDaemons` roots.
    func systemAgents() -> [LaunchAgent] {
        agents(in: systemAgentDirectories, domain: .system, loaded: loadedLabels())
    }

    /// Both domains from a single `launchctl list`.
    ///
    /// `loadedLabels()` shells out to `launchctl`, so a caller that wants the
    /// whole picture — Smart Scan's background-items unit, the Performance
    /// section's reload — would otherwise pay for two subprocess spawns to
    /// build one list. The snapshot is equally valid for both roots, so it is
    /// taken once and threaded through.
    func allAgents() -> [LaunchAgent] {
        let loaded = loadedLabels()
        return agents(in: [userAgentsDirectory], domain: .user, loaded: loaded)
            + agents(in: systemAgentDirectories, domain: .system, loaded: loaded)
    }

    private func agents(
        in roots: [URL],
        domain: LaunchAgent.Domain,
        loaded: Set<String>
    ) -> [LaunchAgent] {
        var seen = Set<String>()
        var result: [LaunchAgent] = []

        for dir in roots {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            let entries = (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries where entry.pathExtension.lowercased() == "plist" {
                // A directory named `*.plist` is not a launch agent; only
                // regular files carry a launchd job definition. Symlinks are
                // resolved first, because dotfile managers link agents into
                // this folder and launchd loads those just the same.
                let isRegularFile = (try? entry.resolvingSymlinksInPath().resourceValues(
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
    /// privilege escalation. `load` exits 0 even when it fails, so launchd's
    /// own list decides whether it worked.
    func enable(_ agent: LaunchAgent) throws {
        try launchctl(["load", "-w", agent.path.path])
        guard loadedLabels().contains(agent.label) else {
            throw LaunchAgentError.stateDidNotChange(label: agent.label)
        }
    }

    /// Unloads the job from launchd via `launchctl unload -w <path>`. The `-w`
    /// flag records the agent as disabled in launchd's per-user override
    /// database (`/var/db/com.apple.xpc.launchd`) so it stays off across logins
    /// rather than reloading on the next session. User agents live in the
    /// caller's own launchd domain, so this needs no privilege escalation.
    /// `unload` exits 0 even when it fails, so launchd's own list decides
    /// whether it worked.
    func disable(_ agent: LaunchAgent) throws {
        try launchctl(["unload", "-w", agent.path.path])
        guard !loadedLabels().contains(agent.label) else {
            throw LaunchAgentError.stateDidNotChange(label: agent.label)
        }
    }

    // MARK: - Remove

    /// Removes a job. A user agent is stopped and its plist moved to the Trash,
    /// because launchd keeps running a job whose plist is gone until logout,
    /// and a user who changes their mind can put the file back. Stopping comes
    /// first so a job that won't stop keeps the plist that describes it. A
    /// plist that is already gone counts as removed, so a list that has fallen
    /// behind the disk can't make a retry fail forever. System-domain plists
    /// under `/Library` require root and are routed through the privileged
    /// helper's `removeLaunchAgent(path:)`.
    func remove(_ agent: LaunchAgent) async throws {
        switch agent.domain {
        case .user:
            try stop(agent)
            guard fileManager.fileExists(atPath: agent.path.path) else { return }
            guard !(await recycle([agent.path])).isEmpty else {
                throw LaunchAgentError.couldNotMoveToTrash(label: agent.label)
            }
        case .system:
            try await removeViaHelper(path: agent.path.path)
        }
    }

    /// Boots the job out of the user's launchd domain. A job that isn't loaded
    /// is already what this asks for.
    private func stop(_ agent: LaunchAgent) throws {
        do {
            try launchctl(["bootout", "gui/\(getuid())/\(agent.label)"])
        } catch let error as NSError where error.domain == Self.launchctlErrorDomain
            && Self.notLoadedExitStatuses.contains(error.code) {
            return
        }
    }

    /// Bridges the reply-block helper call to async/throwing. See `HelperCall`
    /// for the dual reply/error paths and the watchdog that keep a dropped or
    /// wedged connection from freezing removal.
    private func removeViaHelper(path: String) async throws {
        let error = await HelperCall.perform(helperProvider: helperProvider) { helper, reply in
            helper.removeLaunchAgent(path: path, reply: reply)
        }
        if let error {
            log.error("Helper launch-agent removal failed: \(error.localizedDescription, privacy: .private)")
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
    /// `ProgramArguments`, else `BundleProgram`, which is relative to the bundle
    /// that registered the job.
    static func programPath(from plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty {
            return program
        }
        if let arguments = plist["ProgramArguments"] as? [String],
           let first = arguments.first, !first.isEmpty {
            return first
        }
        if let bundleProgram = plist["BundleProgram"] as? String, !bundleProgram.isEmpty {
            return bundleProgram
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
            // `readToEnd()` throws a catchable Swift error; the older
            // `readDataToEndOfFile()` raises an uncatchable NSException that
            // would crash the app if the pipe disconnects unexpectedly.
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
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
        // See `defaultLoadedLabels` — `readToEnd()` fails catchably where
        // `readDataToEndOfFile()` would raise an uncatchable NSException.
        let errorData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = stderr.isEmpty
                ? "launchctl \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)"
                : stderr
            throw NSError(
                domain: LaunchAgentManager.launchctlErrorDomain,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
}
