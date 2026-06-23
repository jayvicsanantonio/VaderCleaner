// DownloadSourceResolver.swift
// Resolves the app that downloaded a file (from its quarantine "agent" string) to a real installed application — display name + bundle id — by matching against an index of installed apps, so any downloader (any browser, Photos, Preview, etc.) is attributed and iconified, not just a hardcoded list.

import AppKit

/// An index of the apps installed on this Mac, keyed by bundle id, display
/// name, and executable name, so a quarantine agent recorded in any of those
/// forms resolves to the same app. Built once by scanning the standard
/// application directories; a `Sendable` value so it can be cached and read
/// from the off-main download scan.
struct AppIndex: Sendable {

    /// A resolved app: the name to show and its bundle id (for the icon).
    struct Ref: Sendable, Equatable {
        let name: String
        let bundleID: String?
    }

    var byBundleID: [String: Ref] = [:]
    var byName: [String: Ref] = [:]
    var byExecutable: [String: Ref] = [:]

    /// The app matching a quarantine agent, trying bundle id, then display
    /// name, then executable name (all case-insensitive).
    func match(agent: String) -> Ref? {
        let key = agent.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return byBundleID[key] ?? byName[key] ?? byExecutable[key]
    }

    /// Scans the standard application directories and reads each bundle's
    /// Info.plist to map its bundle id / display name / executable to the app.
    static func build() -> AppIndex {
        let fileManager = FileManager.default
        var directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) }
        directories.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true))

        var index = AppIndex()
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url) else { continue }
                let info = bundle.infoDictionary
                let fileName = url.deletingPathExtension().lastPathComponent
                let displayName = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? fileName
                let ref = Ref(name: displayName, bundleID: bundle.bundleIdentifier)

                if let bundleID = bundle.bundleIdentifier {
                    index.byBundleID[bundleID.lowercased()] = ref
                }
                index.byName[displayName.lowercased()] = ref
                index.byName[fileName.lowercased()] = ref
                if let executable = info?["CFBundleExecutable"] as? String {
                    index.byExecutable[executable.lowercased()] = ref
                }
            }
        }
        return index
    }
}

/// Resolves a quarantine agent string to a real app. The agent can be recorded
/// as a bundle id ("com.google.Chrome"), a display name ("Safari", "Photos"),
/// or an executable — all handled here against the installed-apps index.
enum DownloadSourceResolver {

    /// Built once on first use (it does directory I/O). Immutable afterwards.
    private static let cachedIndex = AppIndex.build()

    /// (display name, bundle id) for a quarantine agent. The bundle id is `nil`
    /// when no installed app matches, in which case the cleaned agent string is
    /// used as the name.
    static func resolve(agent rawAgent: String, index: AppIndex? = nil) -> (name: String, bundleID: String?) {
        let resolved = index ?? cachedIndex
        // The agent encodes spaces (and other bytes) as `\xNN`, e.g.
        // "Chrome\x20Dev" — decode before matching so it reads and groups right.
        let agent = unescape(rawAgent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty else { return (agent, nil) }

        // 1. Agents recorded as a bundle id resolve directly through
        // LaunchServices (also covers apps outside the scanned directories).
        if isBundleIdentifier(agent),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent) {
            return (displayName(of: url), Bundle(url: url)?.bundleIdentifier ?? agent)
        }

        // 2. Known agent alias → bundle id. The agent is often a short channel
        // name ("Chrome", "Chrome Dev") that doesn't equal the app's name
        // ("Google Chrome"), so map those to the real bundle id. When the app is
        // installed, use its localized name so channels/aliases merge.
        if let bundleID = knownBundleID(for: agent) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return (displayName(of: url), bundleID)
            }
            return (agent, bundleID)
        }

        // 3. Exact match against the installed-apps index (name / executable).
        if let ref = resolved.match(agent: agent) {
            return (ref.name, ref.bundleID)
        }

        // 4. Unknown — keep the cleaned agent as the name.
        return (clean(agent), nil)
    }

    /// Heuristic: a reverse-DNS-looking token (has a dot, no spaces or slashes)
    /// is treated as a bundle id.
    static func isBundleIdentifier(_ string: String) -> Bool {
        string.contains(".") && !string.contains(" ") && !string.contains("/")
    }

    /// Decodes `\xNN` hex escapes (used by the quarantine agent for spaces and
    /// other bytes) into their characters.
    static func unescape(_ string: String) -> String {
        guard string.contains("\\x") else { return string }
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            if string[index] == "\\",
               let xIndex = string.index(index, offsetBy: 1, limitedBy: string.endIndex), xIndex < string.endIndex,
               string[xIndex] == "x",
               let firstHex = string.index(index, offsetBy: 2, limitedBy: string.endIndex), firstHex < string.endIndex,
               let secondHex = string.index(index, offsetBy: 3, limitedBy: string.endIndex), secondHex < string.endIndex,
               let code = UInt32(String(string[firstHex...secondHex]), radix: 16),
               let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
                index = string.index(index, offsetBy: 4)
            } else {
                result.append(string[index])
                index = string.index(after: index)
            }
        }
        return result
    }

    /// Maps a decoded agent (a short channel/app name) to its bundle id, so
    /// downloaders whose agent name differs from their app name still get the
    /// right icon and merge across channels.
    static func knownBundleID(for agent: String) -> String? {
        switch agent.lowercased() {
        case "google chrome", "chrome": return "com.google.Chrome"
        case "google chrome dev", "chrome dev": return "com.google.Chrome.dev"
        case "google chrome beta", "chrome beta": return "com.google.Chrome.beta"
        case "google chrome canary", "chrome canary": return "com.google.Chrome.canary"
        case "chromium": return "org.chromium.Chromium"
        case "safari": return "com.apple.Safari"
        case "firefox", "mozilla firefox": return "org.mozilla.firefox"
        case "firefox developer edition": return "org.mozilla.firefoxdeveloperedition"
        case "microsoft edge", "edge": return "com.microsoft.edgemac"
        case "brave", "brave browser": return "com.brave.Browser"
        case "arc": return "company.thebrowser.Browser"
        case "opera": return "com.operasoftware.Opera"
        case "vivaldi": return "com.vivaldi.Vivaldi"
        case "slack": return "com.tinyspeck.slackmacgap"
        case "discord": return "com.hnc.Discord"
        case "telegram": return "ru.keepcoder.Telegram"
        case "whatsapp": return "net.whatsapp.WhatsApp"
        default: return nil
        }
    }

    /// Strips a trailing ".app" so an unmatched agent still reads cleanly.
    static func clean(_ string: String) -> String {
        string.hasSuffix(".app") ? String(string.dropLast(4)) : string
    }

    private static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// Loads an application's icon from its bundle id, for the Downloads UI.
enum AppIconLoader {
    static func image(bundleID: String?) -> NSImage? {
        guard
            let bundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
